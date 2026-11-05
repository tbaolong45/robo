// `robo chat`: a text-only debug REPL on the same agent client as the app.
import Foundation
import RoboCore
import RoboSystem

/// Ctrl-C while a run is going stops that run; at the prompt it ends the REPL.
private final class Interrupt {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var runID: String?
    private var source: DispatchSourceSignal?

    func begin(_ task: Task<Void, Never>) { lock.withLock { self.task = task; runID = nil } }
    func started(_ id: String) { lock.withLock { runID = id } }
    func end() { lock.withLock { task = nil } }
    func take() -> (task: Task<Void, Never>, runID: String?)? {
        lock.withLock { task.map { (task: $0, runID: runID) } }
    }

    func install(_ agent: AgentAPI, write: @escaping (String) -> Void) {
        signal(SIGINT, SIG_IGN)
        let s = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        s.setEventHandler { [self] in
            guard let run = take() else { exit(0) }
            run.task.cancel()
            if let id = run.runID { Task { try? await agent.stop(id) } }
            write("\n[stopped]\n")
        }
        s.resume()
        source = s
    }
}

/// The loop: a prompt, one line, the reply's events printed as they arrive. Returns 0 at the end of input.
func runChat(_ agent: AgentAPI, session: String, readLine: () -> String? = { Swift.readLine() },
                    write: @escaping (String) -> Void = { print($0, terminator: ""); fflush(stdout) },
                    handleCtrlC: Bool = true) async -> Int32 {
    let interrupt = Interrupt()
    if handleCtrlC { interrupt.install(agent, write: write) }
    while true {
        write("you> ")
        guard let line = readLine() else { return 0 }
        let text = line.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty { continue }
        let task = Task {
            do {
                for try await ev in agent.ask(text, sessionId: session, started: { interrupt.started($0) }) {
                    switch ev {
                    case .feeling(let e): write("[\(e)] ")
                    case .delta(let t): write(t)
                    case .toolStarted(let tool): write("\n  (\(tool)…)\n")
                    case .runEnded(let status, _, let error): write(status == "completed" ? "\n" : "\n[\(status)] \(error)\n")
                    default: break
                    }
                }
            } catch let e as BrainError {
                write("[error] \(e.message)\n")
            } catch {
                if !Task.isCancelled { write("[error] \(error)\n") }
            }
        }
        interrupt.begin(task)
        await task.value
        interrupt.end()
    }
}

/// `robo chat` for real: the agent of this Mac, started if it is not up (and stopped at the end if this started it), with robo's
/// Brave made sure of first, unless ROBO_AGENT_URL points elsewhere (see `DevSwitches`).
public func chatMain(environment: [String: String] = ProcessInfo.processInfo.environment) async -> Int32 {
    let agent = AgentHome(env: environment)
    do {
        let c = try agent.clientConnection()
        let service = agent.service()
        defer { service?.stop() }
        let session = "robo-chat-\(CalendarDay().iso)-\(agent.personaStamp())"
        return await runChat(AgentKeeper(AgentClient(baseURL: c.url, key: c.key), service: service, hasKey: { agent.hasDeepSeekKey }),
                             session: session)
    } catch {
        Host.warn("robo: \(error)")
        return 1
    }
}
