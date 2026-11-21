import DSCore
import Foundation

/// Wi-Fi 策略切换、批量暂停/恢复与串行化协调扩展（拆分自 DownloadCoordinator 保持单文件 <= 400 行）
extension DownloadCoordinator {
    /// 动态同步 Wi-Fi 策略与并发上限（UI-02 / SYS2-03：切 5G 自动暂停进行中任务，回连 Wi-Fi 自动续传，串行化策略切换）
    public func updatePolicy(wifiOnly: Bool, maxManualConcurrent: Int, isOnWiFi: Bool) {
        wifiOnlyEnabled = wifiOnly
        isCurrentlyOnWiFi = isOnWiFi
        let clamped = max(1, min(6, maxManualConcurrent))
        if scheduler.maxManualConcurrent != clamped {
            let activeM = scheduler.activeManualIDs
            let activeP = scheduler.activePrecacheIDs
            var next = DownloadScheduler(maxManualConcurrent: clamped, maxPrecacheConcurrent: 1)
            for id in activeM { next.markStarted(id: id, kind: .manual) }
            for id in activeP { next.markStarted(id: id, kind: .precache) }
            scheduler = next
        }
        if wifiOnlyEnabled && !isCurrentlyOnWiFi {
            enqueuePolicyTransition { [weak self] in
                guard let self, self.wifiOnlyEnabled && !self.isCurrentlyOnWiFi else { return }
                let activeIDs = self.allRecordsByID.values.filter { $0.state.isActive }.map(\.id)
                guard !activeIDs.isEmpty else { return }
                self.autoPausedForCellularIDs.formUnion(activeIDs)
                await self.pauseBatch(ids: activeIDs)
            }
            return
        }
        if !autoPausedForCellularIDs.isEmpty {
            enqueuePolicyTransition { [weak self] in
                guard let self, !(self.wifiOnlyEnabled && !self.isCurrentlyOnWiFi) else { return }
                let toResume = Array(self.autoPausedForCellularIDs)
                self.autoPausedForCellularIDs.removeAll()
                await self.resumeBatch(ids: toResume)
            }
            return
        }
        scheduleNextIfPossible()
    }

    /// 批量暂停全部进行中/排队任务（B9-02：单事务批量落盘 + 单次刷新 + 串行化策略链）
    public func pauseAll() async {
        let task = enqueuePolicyTransition { [weak self] in
            guard let self else { return }
            self.autoPausedForCellularIDs.removeAll()
            let targets = self.allRecordsByID.values
                .filter { $0.state == .queued || $0.state == .resolving || $0.state == .downloading }
                .map(\.id)
            await self.pauseBatch(ids: targets)
        }
        await task.value
    }

    /// 批量继续全部已暂停/失败任务（B9-02：单事务批量落盘 + 单次调度 + 串行化策略链）
    public func resumeAll() async {
        let task = enqueuePolicyTransition { [weak self] in
            guard let self else { return }
            let targets = self.allRecordsByID.values
                .filter { $0.state == .paused || $0.state == .failed }
                .map(\.id)
            await self.resumeBatch(ids: targets)
        }
        await task.value
    }

    public func invalidateResumeDataOnAuthOrNetworkChange() {
        transport.invalidateAllResumeData()
    }

    @discardableResult
    private func enqueuePolicyTransition(_ operation: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = policyTransitionTask
        let next = Task { @MainActor in
            await previous?.value
            await operation()
        }
        policyTransitionTask = next
        return next
    }

    private func pauseBatch(ids: [String]) async {
        guard !ids.isEmpty else { return }
        var updated: [DownloadRecordSnapshot] = []
        updated.reserveCapacity(ids.count)
        for id in ids {
            guard let initial = allRecordsByID[id], initial.state.canTransition(to: .paused) else { continue }
            resolveTasks[id]?.cancel()
            resolveTasks.removeValue(forKey: id)
            retryTasks[id]?.cancel()
            retryTasks.removeValue(forKey: id)
            progressSampleByTaskID.removeValue(forKey: id)
            progressFeed.clearSpeed(for: id)
            await transport.pauseDownload(taskID: id)
            scheduler.markFinished(id: id)
            guard var latest = allRecordsByID[id], latest.state.canTransition(to: .paused) else { continue }
            latest.state = .paused
            allRecordsByID[id] = latest
            updated.append(latest)
        }
        if !updated.isEmpty {
            try? await persistence.upsertDownloadsBatch(updated)
            refreshManualRecords()
        }
        scheduleNextIfPossible()
    }

    private func resumeBatch(ids: [String]) async {
        var updated: [DownloadRecordSnapshot] = []
        updated.reserveCapacity(ids.count)
        for id in ids {
            guard var rec = allRecordsByID[id],
                  rec.state == .paused || rec.state == .failed || rec.state == .cancelled,
                  rec.state.canTransition(to: .queued) else { continue }
            retryTasks[id]?.cancel()
            retryTasks.removeValue(forKey: id)
            rec.state = .queued
            rec.retryCount = 0
            rec.retryNotBefore = nil
            rec.errorMessage = nil
            allRecordsByID[id] = rec
            updated.append(rec)
        }
        if !updated.isEmpty {
            try? await persistence.upsertDownloadsBatch(updated)
            refreshManualRecords()
        }
        scheduleNextIfPossible()
    }
}
