import Foundation

/// Typed device operations used by multi-command light workflows. Raw
/// protocol method names remain inside YeelightClient.
enum LightWorkflowOperation: Equatable {
    case setPower(Bool)
    case setBright(Int)
    case setCT(Int)
    case setBGPower(Bool)
    case setBGBright(Int)
    case setBGRGB(Int)
    case startBGFlow(String)
    case stopBGFlow
}

struct LightWorkflowPlan: Equatable {
    let operations: [LightWorkflowOperation]

    static func scene(_ scene: ScenePreset) -> Self {
        var operations: [LightWorkflowOperation] = []
        if scene.mainPower {
            operations += [.setPower(true), .setBright(scene.mainBright), .setCT(scene.mainCT)]
        } else {
            operations.append(.setPower(false))
        }
        if scene.bgPower {
            operations += [.setBGPower(true), .setBGRGB(scene.bgRGB), .setBGBright(scene.bgBright)]
        } else {
            operations.append(.setBGPower(false))
        }
        return Self(operations: operations)
    }

    static func restore(_ snapshot: LightState) -> Self {
        var operations: [LightWorkflowOperation] = [.setPower(snapshot.mainPower)]
        if snapshot.mainPower {
            operations += [.setBright(snapshot.bright), .setCT(snapshot.ct)]
        }
        operations.append(.setBGPower(snapshot.bgPower))
        if snapshot.bgPower {
            operations += [.setBGBright(snapshot.bgBright), .setBGRGB(snapshot.bgRGB)]
        }
        return Self(operations: operations)
    }

    static func restoreBacklight(_ snapshot: LightState) -> Self {
        var operations: [LightWorkflowOperation] = [.setBGPower(snapshot.bgPower)]
        if snapshot.bgPower {
            operations += [.setBGBright(snapshot.bgBright), .setBGRGB(snapshot.bgRGB)]
        }
        return Self(operations: operations)
    }
}

struct LightWorkflowFailure: Error {
    let operation: LightWorkflowOperation
    let completedCount: Int
    let underlying: Error
}

enum LightWorkflowRunner {
    static func run(
        _ plan: LightWorkflowPlan,
        execute: (LightWorkflowOperation) async throws -> Void
    ) async throws {
        for (index, operation) in plan.operations.enumerated() {
            do {
                try Task.checkCancellation()
                try await execute(operation)
            } catch {
                throw LightWorkflowFailure(
                    operation: operation,
                    completedCount: index,
                    underlying: error)
            }
        }
    }
}
