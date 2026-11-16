import Foundation

// Синтетический замер текущего производственного запроса и очистки ответа.
// Точность на этих примерах не является оценкой повседневного качества.
func kbLog(_ message: String) { print("log: \(message)") }
enum AutocompletePrefs { static var idleUnloadMinutes = 60 }
struct Fixture { let id:String; let context:CompletionContext; let target:String }
var fixtures:[Fixture]=[]
for (index,pair) in [("The project launch code is","SAPPHIRE7392"),("The internal project name is","Silver Orchard"),("Название проекта","Серебряный сад")].enumerated() {
 let (before,target)=pair;let base=CompletionContext(appName:"Synthetic",before:before);let fact=before+" "+target+"."
 var clip=base;clip.clipboard=fact
 var instruction=base;instruction.globalInstruction=fact+" Use that value in the completion."
 var history=base;history.snippets=[fact];history.terms=[target]
 for (kind,c) in [("baseline",base),("clipboard",clip),("instruction",instruction),("history",history)] {fixtures.append(Fixture(id:"original-\(index)-\(kind)",context:c,target:kind == "baseline" ? "" : target))}
}
var c=CompletionContext(appName:"Mail",before:"The deployment is scheduled for ");c.clipboard="Release plan: deployment is scheduled for Thursday at 14:30.";fixtures.append(Fixture(id:"heldout-en-clip",context:c,target:"Thursday"))
c=CompletionContext(appName:"Почта",before:"Встреча команды состоится ");c.clipboard="Договорились: встреча команды состоится в пятницу в 11:00.";fixtures.append(Fixture(id:"heldout-ru-clip",context:c,target:"в пятницу"))
c=CompletionContext(appName:"Team chat",before:"The feature is ready for ");c.globalInstruction="When referring to testing a finished feature, write peer verification rather than QA.";fixtures.append(Fixture(id:"heldout-en-global",context:c,target:"peer verification"))
c=CompletionContext(appName:"Рабочий чат",before:"Задача готова к ");c.globalInstruction="Проверку готовой задачи называй «проверке коллегой». Пиши кратко, без канцелярита.";fixtures.append(Fixture(id:"heldout-ru-global",context:c,target:"проверке коллегой"))
c=CompletionContext(appName:"Issue tracker",before:"Please move this issue to ");c.appInstruction="The status after development in this app is called Peer Check. Use the exact status name.";fixtures.append(Fixture(id:"heldout-en-app",context:c,target:"Peer Check"))
c=CompletionContext(appName:"Задачи",before:"Переведи задачу в статус ");c.appInstruction="В этом приложении статус после разработки называется «Проверка команды». Указывай название статуса дословно.";fixtures.append(Fixture(id:"heldout-ru-app",context:c,target:"Проверка команды"))
c=CompletionContext(appName:"Notes",before:"We use ");c.snippets=["We use RiverCache for all session data.","RiverCache keeps session data close to the service."];c.terms=["RiverCache"];fixtures.append(Fixture(id:"heldout-en-history",context:c,target:"RiverCache"))
c=CompletionContext(appName:"Заметки",before:"Для хранения сессий используем ");c.snippets=["Для хранения сессий используем РекаКэш.","РекаКэш хранит сессии рядом с сервисом."];c.terms=["РекаКэш"];fixtures.append(Fixture(id:"heldout-ru-history",context:c,target:"РекаКэш"))

guard let model = CompletionModels.all.first(where: { CompletionModels.isInstalled($0) }) else { exit(1) }
let engine = CompletionEngine.shared
engine.ensureRunning(model: CompletionModels.localURL(model))
let deadline = Date().addingTimeInterval(40)
while engine.state != .ready && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
guard engine.state == .ready else { print("FAIL: helper not ready"); engine.stop(); exit(1) }
let runtimeSampling = CommandLine.arguments.contains("--runtime")
let temperature = runtimeSampling ? 0.2 : 0.0
let maxTokens = runtimeSampling ? 20 : 24
let seed: Int? = runtimeSampling ? (Int(ProcessInfo.processInfo.environment["SPEAKEY_PROBE_SEED"] ?? "") ?? 42) : nil
var baselinePrompts: [String: String] = [:]
if let path = ProcessInfo.processInfo.environment["SPEAKEY_PROBE_BASELINE_PROMPTS"] {
    baselinePrompts = try! JSONDecoder().decode([String: String].self, from: Data(contentsOf: URL(fileURLWithPath: path)))
    guard fixtures.allSatisfy({ baselinePrompts[$0.id] != nil }) else { engine.stop(); exit(2) }
}
var results: [[String: Any]] = []
for fixture in fixtures {
    var context = fixture.context
    let endsSpace = context.before.hasSuffix(" ") && !context.before.hasSuffix("  ")
    if endsSpace { context.before.removeLast() }
    let arms = baselinePrompts[fixture.id].map { [("before", $0), ("after", CompletionPrompt.build(context))] }
        ?? [("after", CompletionPrompt.build(context))]
    for (arm, prompt) in arms {
    let armTemperature = arm == "after" ? CompletionPrompt.continuationTemperature : temperature
    var raw: String?
    var completed = false
    let start = Date()
    engine.complete(prompt: prompt, maxTokens: maxTokens, temperature: armTemperature, seed: seed) { raw = $0; completed = true }
    while !completed && Date().timeIntervalSince(start) < 15 { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
    var adjusted = raw ?? ""
    let validBoundary = !endsSpace || adjusted.first == " "
    if endsSpace && validBoundary { adjusted.removeFirst() }
    let cleaned = validBoundary
        ? (arm == "before" ? CompletionText.clean(adjusted, before: fixture.context.before, maxWords: 6) : CompletionPrompt.cleanContinuation(adjusted, before: fixture.context.before, context: context, maxWords: 6))
        : ""
    let row: [String: Any] = ["temperature": armTemperature, "arm": arm, "id": fixture.id, "before": fixture.context.before, "target": fixture.target,
        "response": raw ?? "", "cleaned": cleaned, "completed": completed, "response_available": raw != nil,
        "valid_word_boundary": validBoundary,
        "target_present": !fixture.target.isEmpty && cleaned.localizedCaseInsensitiveContains(fixture.target),
        "elapsed_ms": Int(Date().timeIntervalSince(start) * 1000)]
    results.append(row)
    print(String(data: try! JSONSerialization.data(withJSONObject: row, options: [.sortedKeys, .withoutEscapingSlashes]), encoding: .utf8)!)
    }
}
engine.stop()
let data = try! JSONSerialization.data(withJSONObject: ["model": model.id, "before_temperature": temperature, "after_temperature": CompletionPrompt.continuationTemperature, "max_tokens": maxTokens, "seed": seed as Any? ?? NSNull(), "results": results], options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
if CommandLine.arguments.count > 1 { try! data.write(to: URL(fileURLWithPath: CommandLine.arguments[1])) }
exit(results.allSatisfy { $0["completed"] as? Bool == true && $0["response_available"] as? Bool == true } ? 0 : 1)
