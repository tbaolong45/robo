// `robo` opens the floating robo. `robo setup` prepares Hermes, `robo signin` opens robo's Brave for school
// sign-ins, `robo chat` is a text-only REPL, `robo activity` summarises what you did on this laptop,
// `robo plan` packs study blocks into free time (JSON in, JSON out), `robo calendar` keeps the calendar links
// of the deadline nudges, `robo voice-eval` scores the voice pipeline. Thin on purpose: every command lives in its own module (cli.py).
import Foundation
import RoboCore
import RoboSystem
import RoboUI
import RoboVoice

let usage = """
    usage: robo [-h] [--moodle URL] [--days DAYS] [--day DAY]
                [{setup,signin,chat,activity,plan,calendar,voice-eval}]

    `robo` opens the floating robo. `robo setup` prepares Hermes, `robo signin` opens robo's Brave
    for school sign-ins, `robo chat` is a text-only REPL, `robo activity` summarises what you did on
    this laptop, `robo plan` packs study blocks into free time (JSON in, JSON out), `robo calendar`
    keeps your calendar links for the deadline nudges (`add URL [--label NAME]`, `list`, `remove LABEL`,
    `check`; the links go into a private file and are never printed).

    options:
      -h, --help    show this help message and exit
      --moodle URL  with setup: your Moodle address
      --days DAYS   with activity: how many days
      --day DAY     with activity: last day

    """

var args = Array(CommandLine.arguments.dropFirst())
let command = args.isEmpty ? nil : args.removeFirst()
switch command {
case nil:
    exit(RoboApp.run())
case "plan":  // robo plan --tasks ... --busy ... (used by the study-plan skill)
    let out = planMain(args)
    FileHandle.standardOutput.write(Data(out.stdout.utf8))
    FileHandle.standardError.write(Data(out.stderr.utf8))
    exit(out.status)
case "activity":
    exit(runActivity(args))
case "setup":
    exit(runSetup(args))
case "signin":
    exit(runSignin())
case "calendar":
    exit(await runCalendar(args))
case "chat":
    exit(await chatMain())
case "voice-eval":
    exit(runVoiceEval(args))
case "-h", "--help":
    print(usage, terminator: "")
    exit(0)
default:
    Host.warn("\(usage)robo: error: argument command: invalid choice: '\(command!)' "
              + "(choose from setup, signin, chat, activity, plan, calendar, voice-eval)")
    exit(2)
}
