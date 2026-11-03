import SiltaCore
import SiltaTestSupport
import Testing

struct TaskErrorTests {
  @Test func textAndJSONRecoveryMatchWrittenContract() {
    let errors: [any CodedError] =
      TaskError.examples.map { $0 as any CodedError } + [
        CommandBusyError(command: "silta task add")
      ]
    Golden.forTests().check(
      errors.map {
        OutputRouter.render(.failure($0), mode: OutputMode(json: false)).stderr
      }.joined(), "task-errors.txt")
    Golden.forTests().check(
      errors.map {
        OutputRouter.render(.failure($0), mode: OutputMode(json: true)).stdout
      }.joined(), "task-errors.json")
  }
}
