//
//  GroupRepository.swift
//  FeiQMac
//
//  群组业务仓储：维护群组内存索引，并将群组资料持久化到历史服务。
//

import Foundation

protocol GroupRepository: AnyObject {
    func save(_ group: ChatGroup)
    func delete(groupID: String)
    func restore(_ groups: [ChatGroup])
    func groups(containing memberID: String) -> [ChatGroup]
}

final class DefaultGroupRepository: GroupRepository {
    private let historyService: ChatHistoryService
    private let queue = DispatchQueue(label: "com.feiqmac.group-repository-state")
    private var groupsByID: [String: ChatGroup] = [:]

    init(historyService: ChatHistoryService) {
        self.historyService = historyService
    }

    func save(_ group: ChatGroup) {
        queue.sync {
            groupsByID[group.id] = group
        }
        historyService.saveGroup(group)
    }

    func delete(groupID: String) {
        _ = queue.sync {
            groupsByID.removeValue(forKey: groupID)
        }
        historyService.deleteGroup(groupID)
    }

    func restore(_ groups: [ChatGroup]) {
        queue.sync {
            for group in groups {
                groupsByID[group.id] = group
            }
        }
    }

    func groups(containing memberID: String) -> [ChatGroup] {
        queue.sync {
            groupsByID.values
                .filter { $0.memberIDs.contains(memberID) }
                .sorted { $0.createdAt < $1.createdAt }
        }
    }
}
