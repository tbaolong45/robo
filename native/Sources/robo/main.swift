// `robo` opens the floating robo. `robo setup` prepares its chat service and the login item, `robo key` stores the DeepSeek key,
// `robo chat` is a text-only REPL, `robo voice-eval` scores the voice pipeline. Thin on purpose: every command lives in its own module.
import Foundation
import RoboSystem
import RoboUI
import RoboVoice

let usage = """
    usage: robo [-h] [{setup,key,chat,voice-eval}]

    `robo` opens the floating robo. `robo setup` prepares robo's chat service and the login item, `robo key`
    stores the DeepSeek API key (`set deepseek`: the key is read from the terminal, not shown, or from stdin;
    `status` says only set or not set), `robo chat` is a text-only REPL, `robo voice-eval` scores the voice pipeline.

    options:
      -h, --help    show this help message and exit

    """

var args = Array(CommandLine.arguments.dropFirst())
let command = args.isEmpty ? nil : args.removeFirst()
switch command {
case nil:
    exit(RoboApp.run())
case "setup":
    exit(runSetup(args))
case "key":
    exit(runKey(args))
case "chat":
    exit(await chatMain())
case "voice-eval":
    exit(runVoiceEval(args))
case "-h", "--help":
    print(usage, terminator: "")
    exit(0)
default:
    Host.warn("\(usage)robo: error: argument command: invalid choice: '\(command!)' "
              + "(choose from setup, key, chat, voice-eval)")
    exit(2)
}
