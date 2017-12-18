import UIKit

// MARK: - UIStylesheetManager

public enum ParseError: Error {
  /// Illegal format for the stylesheet.
  case malformedStylesheetStructure(message: String?)
  /// An illegal use of a '!!func' in the stylesheet.
  case illegalNumberOfArguments(function: String?)
}

public class UIStylesheetManager {
  public static let `default` = UIStylesheetManager()
  /// The default debug remote fetch url.
  public var debugRemoteUrl: String = "http://localhost:8000/"
  /// The parsed *Yaml* document.
  public var defs: [String: [String: UIStylesheetRule]] = [:]
  /// Available animators.
  public var animators: [String: [String: UIViewPropertyAnimator]] = [:]

  /// The current component canvas.
  public var canvasSize: CGSize = UIScreen.main.bounds.size
  /// The stylesheet file currently loaded.
  private var file: String?

  /// Returns the rule named 'name' of a specified style.
  public func rule(style: String, name: String) -> UIStylesheetRule? {
    return defs[style]?[name]
  }

  /// Returns the rule named 'name' of a specified style.
  public func animator(style: String, name: String) -> UIViewPropertyAnimator? {
    return animators[style]?[name]
  }

  private func loadFileFromRemoteServer(_ file: String) -> String? {
    guard DebugFlags.isHotReloadInSimulatorEnabled else { return nil }
    guard let url = URL(string: "\(debugRemoteUrl)\(file).yaml") else { return nil }
    return try? String(contentsOf: url, encoding: .utf8)
  }

  private func loadFileFromBundle(_ file: String) -> String? {
    guard let leaf = file.components(separatedBy: "/").last else { return nil }
    guard let path = Bundle.main.path(forResource: leaf, ofType: "yaml") else { return nil }
    return try? String(contentsOfFile: path, encoding: .utf8)
  }

  private func resolve(file: String) -> String {
    #if (arch(i386) || arch(x86_64)) && os(iOS)
      if let content = loadFileFromRemoteServer(file) {
        return content
      } else if let content = loadFileFromBundle(file) {
        return content
      }
    #else
      if let content = loadFileFromBundle(file) {
        return content
      }
    #endif
    return ""
  }

  public func load(file: String?) throws {
    if file != nil {
      self.file = file
    }
    guard let file = file ?? self.file else {
      warn("nil filename.")
      return
    }
    try load(yaml: resolve(file: file))
  }

  /// Parses the markup content passed as argument.
  public func load(yaml string: String) throws {
    let startTime = CFAbsoluteTimeGetCurrent()

    // Parses the top level definitions.
    var yamlDefs: [String: [String: UIStylesheetRule]] = [:]
    var yamlAnimators: [String: [String: UIViewPropertyAnimator]] = [:]
    var content: String = string

    // Sanitize the file format.
    func validateRootNode(_ string: String) throws -> [Yaml: Yaml] {
      let yaml = try Yaml.load(string)
      guard let root = yaml.dictionary else {
        throw ParseError.malformedStylesheetStructure(message: "The root node should be a map.")
      }
      return root
    }
    // Resolve the import statements in the yaml stylesheet.
    // 'import' statements are only allowed from the main file and they are not processed
    // recursively.
    func resolveImports(_ string: String) throws {
      if string.isEmpty {
        warn("Resolved stylesheet file with empty content.")
        return
      }
      let root = try validateRootNode(string)
      for imported in root["import"]?.array ?? [] {
        guard let fileName = imported.string?.replacingOccurrences(of: ".yaml", with: "") else {
          continue
        }
        content += resolve(file: fileName)
      }
    }
    // Parse the final stylesheet file.
    func parseRoot(_ string: String) throws {
      let root = try validateRootNode(string)
      for (key, value) in root {
        guard key != "import" else { continue }
        guard var defDic = value.dictionary, let defKey = key.string else {
          throw ParseError.malformedStylesheetStructure(message:"Definitions should be maps.")
        }
        // In yaml definitions can inherit from others using the <<: *ID expression. e.g.
        // myDef: &_myDef
        //   foo: 1
        // myOtherDef: &_myOtherDef
        //   <<: *_myDef
        //   bar: 2
        var defs: [String: UIStylesheetRule] = [:]
        if let inherit = defDic["<<"]?.dictionary {
          for (ik, iv) in inherit {
            guard let isk = ik.string else {
              throw ParseError.malformedStylesheetStructure(message: "Invalid rule key.")
            }
            defs[isk] = try UIStylesheetRule(key: isk, value: iv)
          }
        }
        let animatorPrefix = "animator-"
        for (k, v) in defDic {
          guard let sk = k.string, sk != "<<", !sk.hasPrefix(animatorPrefix) else { continue }
          defs[sk] = try UIStylesheetRule(key: sk, value: v)
        }
        // Optional transition store.
        var animators: [String: UIViewPropertyAnimator] = [:]
        for (k, v) in defDic {
          guard let sk = k.string, sk.hasPrefix(animatorPrefix) else { continue }
          let processedKey = sk.replacingOccurrences(of: animatorPrefix, with: "")
          animators[processedKey] = try UIStylesheetRule(key: processedKey, value: v).animator
        }
        yamlAnimators[defKey] = animators
        yamlDefs[defKey] = defs
      }
    }

    try resolveImports(string)
    try parseRoot(content)
    self.defs = yamlDefs
    self.animators = yamlAnimators

    debugLoadTime("\(Swift.type(of: self)).load", startTime: startTime)
  }
}

private func debugLoadTime(_ label: String, startTime: CFAbsoluteTime){
  let timeElapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
  print(String(format: "\(label) (%2f) ms.", arguments: [timeElapsed]))
}

// MARK: - UIStylesheetRule

/// Represents a rule for a style definition.
public class UIStylesheetRule: CustomStringConvertible {
  /// Internal value type store.
  enum ValueType: String {
    case expression
    case bool
    case number
    case string
    case font
    case color
    case animator
    case undefined
  }
  private typealias ConditionalStoreType = [(Expression, Any?)]

  /// The key for this value.
  var key: String
  /// The value type.
  var type: ValueType!
  /// The computed value.
  var store: Any?
  /// Whether ther store is of type *ConditionalStoreType*.
  var isConditional: Bool = false

  /// Construct a rule from a Yaml subtree.
  init(key: String, value: Yaml) throws {
    self.key = key
    let (type, store, isConditional) = try parseValue(for: value)
    (self.type, self.store, self.isConditional) = (type, store, isConditional)
  }

  /// Returns this rule evaluated as an integer.
  /// - Note: The default value is 0.
  public var integer: Int {
    return (nsNumber as? Int) ?? 0
  }
  /// Returns this rule evaluated as a float.
  /// - Note: The default value is 0.
  public var cgFloat: CGFloat {
    return (nsNumber as? CGFloat) ?? 0
  }
  /// Returns this rule evaluated as a boolean.
  /// - Note: The default value is *false*.
  public var bool: Bool {
    return (nsNumber as? Bool) ?? false
  }
  /// Returns this rule evaluated as a *UIFont*.
  public var font: UIFont {
    return castType(type: .font, default: UIFont.init())
  }
  /// Returns this rule evaluated as a *UIColor*.
  /// - Note: The default value is *UIColor.black*.
  public var color: UIColor {
    return castType(type: .color, default: UIColor.init())
  }
  /// Returns this rule evaluated as a string.
  public var string: String {
    return castType(type: .string, default: String.init())
  }
  /// Retruns this rule as a *UIViewPropertyAnimator*.
  public var animator: UIViewPropertyAnimator {
    return castType(type: .animator, default: UIViewPropertyAnimator())
  }
  /// Object representation for the *rhs* value of this rule.
  public var object: AnyObject? {
    switch type {
    case .bool, .number, .expression:
      return nsNumber
    case .font:
      return font
    case .color:
      return color
    case .string:
      return (string as NSString)
    case .animator:
      return animator
    default:
      return nil
    }
  }

  /// Returns the rule value as the desired return type.
  /// - Note: The enum type should be backed by an integer store.
  public func `enum`<T: UIStylesheetRepresentableEnum>(_ type: T.Type,
                                                       default: T = T.init(rawValue: 0)!) -> T {
    return T.init(rawValue: integer) ?? `default`
  }

  private func castType<T>(type: ValueType, default: T) -> T {
    /// There's a type mismatch between the desired type and the type currently associated to this
    /// rule.
    guard self.type == type else {
      warn("type mismatch – wanted \(type), found \(self.type).")
      return `default`
    }
    /// The rule is a map {EXPR: VALUE}.
    if isConditional {
      return evaluateConditional(variable: self.store, default: `default`)
    }
    /// Casts the store value as the desired type *T*.
    if let value = self.store as? T {
      return value
    }
    return `default`
  }

  /// Evaluates the return value for the *ConditionalStoreType* variable passed as argument.
  private func evaluateConditional<T>(variable: Any?, default: T) -> T {
    // This function is invoked if 'isConditional' is true.
    if let store = variable as? ConditionalStoreType {
      for entry in store {
        guard let value = entry.1 else { continue }
        // Tries to evaluate the condition.
        if !evaluate(expression: entry.0).isZero {
          // The value might be an expression - in that case it evaluates it.
          if let expr = value as? Expression {
            return (evaluate(expression: expr) as? T) ?? `default`
          }
          // Return the casted to the desired type.
          return (value as? T) ?? `default`
        }
      }
    }
    return `default`
  }

  static private let defaultExpression = Expression("0")
  /// Main entry point for numeric return types and expressions.
  /// - Note: If it fails evaluating this rule value, *NSNumber* 0.\
  public var nsNumber: NSNumber {
    let `default` = NSNumber(value: 0)
    // The rule is a map {EXPR: VALUE}.
    if isConditional {
      return evaluateConditional(variable: self.store, default: `default`)
    }
    // If the store is an expression, it must be evaluated first.
    if type == .expression {
      let expression = castType(type: .expression, default: UIStylesheetRule.defaultExpression)
      return NSNumber(value: evaluate(expression: expression))
    }
    // The store is *NSNumber* obj.
    if type == .bool || type == .number, let nsNumber = store as? NSNumber {
      return nsNumber
    }
    return `default`
  }

  /// Tentatively tries to evaluate an expression.
  /// - Note: Returns 0 if the evaluation fails.
  private func evaluate(expression: Expression?) -> Double {
    guard let expression = expression else {
      warn("nil expression.")
      return 0
    }
    do {
      return try expression.evaluate()
    } catch {
      warn("Unable to evaluate expression: \(expression.description).")
      return 0
    }
  }

  /// Parse the *rhs* value of a rule.
  private func parseValue(for yaml: Yaml) throws -> (ValueType, Any?, Bool) {
    switch yaml {
    case .bool(let v):
      return(.bool, v, false)
    case .double(let v):
      return (.number, v, false)
    case .int(let v):
      return (.number, v, false)
    case .string(let v):
      let result = try parse(string: v)
      return (result.0, result.1, false)
    case .dictionary(let v):
      let result = try parse(conditionalDictionary: v)
      return (result.0, result.1, true)
    default: return (.undefined, nil, false)
    }
  }

  /// Parse a map value.
  /// - Note: The lhs is an expression and the rhs a value. 'default' is a tautology.
  private func parse(conditionalDictionary: [Yaml: Yaml]) throws -> (ValueType, Any?) {
    // Used to determine the return value of this rule.
    // This has to be homogeneous across all of the different conditions.
    var types: [ValueType] = []
    // The result is going to be an array of typles (Expression, Any?).
    var result: ConditionalStoreType = []
    for (key, yaml) in conditionalDictionary {
      // Ensure that the key is a well-formed expression.
      guard let string = key.string, let expression = parseExpression(string) else {
        throw ParseError.malformedStylesheetStructure(message: "\(key) is not a valid expression.")
      }
      // Parse the *rhs* value.
      let value = try parseValue(for: yaml)
      // Build the tuple (Expression, Any?).
      let tuple = (UIStylesheetExpression.builder(expression), value.1)
      types.append(value.0)
      // The *default* condition is inserted at the end of the array.
      if string.contains("default") {
        result.append(tuple)
      } else {
        // There's not predefined order for the other conditions and it's up to the user
        // to have exhaustive and non-overlapping conditions.
        result.insert(tuple, at: 0)
      }
    }
    // Sanitize the return types.
    let type = types.first ?? .undefined
    return (type, result)
  }

  /// Parse a string value.
  /// - Note: This could be an expression (e.g. "${1==1}"), a function (e.g. "font(Arial, 42)")
  /// or a simple string.
  private func parse(string: String) throws -> (ValueType, Any?) {
    struct Token {
      static let functionBrackets = ("(", ")")
      static let functionDelimiters = (",")
      static let fontFunction = "font"
      static let colorFunction = "color"
      static let transitionFunction = "animator"
    }
    func expression(from string: String) -> Expression? {
      if let exprString = parseExpression(string) {
        return UIStylesheetExpression.builder(exprString)
      }
      return nil
    }
    // Returns the arguments of the function 'function' as an array of strings.
    func arguments(for function: String) -> [String] {
      var substring = string
        .replacingOccurrences(of: function, with: "")
        .replacingOccurrences(of: Token.functionBrackets.0, with: "")
        .replacingOccurrences(of: Token.functionBrackets.1, with: "")
      substring = substring.trimmingCharacters(in: CharacterSet.whitespaces)
      return substring.components(separatedBy: Token.functionDelimiters)
    }
    // Numbers are boxed as NSNumber.
    func parse(numberFromString string: String) -> NSNumber {
      if let expr = expression(from: string) {
        return NSNumber(value: (try? expr.evaluate()) ?? 0)
      } else {
        return NSNumber(value: (string as NSString).doubleValue)
      }
    }
    // color shorthand
    if string.hasPrefix("#") {
      return (.color, UIColor(hex: string) ?? .black)
    }
    // !!expression
    if let expression = expression(from: string) {
      return (.expression, expression)
    }
    // font
    if string.hasPrefix(Token.fontFunction) {
      let args = arguments(for: Token.fontFunction)
      guard args.count >= 2 else {
        throw ParseError.illegalNumberOfArguments(function: Token.fontFunction)
      }
      let size: CGFloat = CGFloat(parse(numberFromString: args[1]).floatValue)

      if args.count == 3 {
        let weight = parse(numberFromString: args[2]).floatValue
        return (.font, UIFont.systemFont(ofSize: size,
                                         weight: UIFont.Weight(rawValue: CGFloat(weight))))
      }
      return (.font, args[0].lowercased() == "system" ?
        UIFont.systemFont(ofSize: size) : UIFont(name:  args[0], size: size))
    }
    // color
    if string.hasPrefix(Token.colorFunction) {
      let args = arguments(for: Token.colorFunction)
      guard args.count == 1 else {
        throw ParseError.illegalNumberOfArguments(function: Token.colorFunction)
      }
      return (.color, UIColor(hex: args[0]) ?? .black)
    }
    // animator
    if string.hasPrefix(Token.transitionFunction) {
      let args = arguments(for: Token.transitionFunction)
      guard args.count == 2 else {
        throw ParseError.illegalNumberOfArguments(function: Token.transitionFunction)
      }
      //let animator = UIViewPropertyAnimator(duration: 1, curve: .easeIn, animations: nil)
      let duration: TimeInterval = parse(numberFromString: args[0]).doubleValue
      var curve: UIViewAnimationCurve = .linear
      switch args[1] {
      case "easeInOut": curve = .easeInOut
      case "easeIn" : curve = .easeIn
      case "easeOut": curve = .easeOut
      case "linear": curve = .linear
      default: break
      }
      return (.animator, UIViewPropertyAnimator(duration: duration, curve: curve, animations:nil))
    }
    // !!str
    return (.string, string)
  }

  /// Parse an expression.
  /// - Note: The expression delimiters is ${EXPR}.
  private func parseExpression(_ string: String) -> String? {
    struct Token {
      static let expression = "$"
      static let expressionBrackets = ("{", "}")
    }
    guard string.hasPrefix(Token.expression) else { return nil }
    let substring = string
      .replacingOccurrences(of: Token.expression, with: "")
      .replacingOccurrences(of: Token.expressionBrackets.0, with: "")
      .replacingOccurrences(of: Token.expressionBrackets.1, with: "")
    return substring
  }

  /// A textual representation of this instance.
  public var description: String {
    return type.rawValue
  }
}

// MARK: - UIStylesheetExpression

public struct UIStylesheetExpression {

  private static let defaultConstants: [String: Double] = [
    // Idiom.
    "iPhoneSE": Double(UIScreenStateFactory.Idiom.iPhoneSE.rawValue),
    "iPhone8": Double(UIScreenStateFactory.Idiom.iPhone8.rawValue),
    "iPhone8Plus": Double(UIScreenStateFactory.Idiom.iPhone8Plus.rawValue),
    "iPhoneX": Double(UIScreenStateFactory.Idiom.iPhoneX.rawValue),
    "phone": Double(UIScreenStateFactory.Idiom.phone.rawValue),
    "iPad": Double(UIScreenStateFactory.Idiom.iPad.rawValue),
    "tv": Double(UIScreenStateFactory.Idiom.tv.rawValue),
    // Bounds.
    "iPhoneSE.height": Double(568),
    "iPhone8.height": Double(667),
    "iPhone8Plus.height": Double(736),
    "iPhoneX.height": Double(812),
    "iPhoneSE.width": Double(320),
    "iPhone8.width": Double(375),
    "iPhone8Plus.width": Double(414),
    "iPhoneX.width": Double(375),
    // Orientation and Size Classes.
    "portrait": Double(UIScreenStateFactory.Orientation.portrait.rawValue),
    "landscape": Double(UIScreenStateFactory.Orientation.landscape.rawValue),
    "compact": Double(UIScreenStateFactory.SizeClass.compact.rawValue),
    "regular": Double(UIScreenStateFactory.SizeClass.regular.rawValue),
    "unspecified": Double(UIScreenStateFactory.SizeClass.unspecified.rawValue),
    // Yoga.
    "inherit": Double(0),
    "ltr": Double(1),
    "rtl": Double(2),
    "auto": Double(0),
    "flexStart": Double(1),
    "center": Double(2),
    "flexEnd": Double(3),
    "stretch": Double(4),
    "baseline": Double(5),
    "spaceBetween": Double(6),
    "spaceAround": Double(7),
    "flex": Double(0),
    "none": Double(1),
    "column": Double(0),
    "columnReverse": Double(1),
    "row": Double(2),
    "rowReverse": Double(3),
    "visible": Double(0),
    "hidden": Double(1),
    "absolute": Double(2),
    "noWrap": Double(0),
    "wrap": Double(1),
    "wrapReverse": Double(2),
    // Font Weigths.
    "ultralight": Double(-0.800000011920929),
    "thin": Double(-0.600000023841858),
    "light": Double(-0.400000005960464),
    "medium": Double(0.230000004172325),
    "semibold": Double(0.300000011920929),
    "bold": Double(0.400000005960464),
    "heavy": Double(0.560000002384186),
    "black": Double(0.620000004768372),
  ]
  static private let defaultSymbols: [Expression.Symbol: Expression.Symbol.Evaluator] = [
    .variable("idiom"): { _ in
      Double(UIScreenStateFactory.Idiom.current().rawValue) },
    .variable("orientation"): { _ in
      Double(UIScreenStateFactory.Orientation.current().rawValue) },
    .variable("verticalSizeClass"): { _ in
      Double(UIScreenStateFactory.SizeClass.verticalSizeClass().rawValue) },
    .variable("horizontalSizeClass"): { _ in
      Double(UIScreenStateFactory.SizeClass.horizontalSizeClass().rawValue) },
    .variable("canvasSize.height"): { _ in
      Double(UIStylesheetManager.default.canvasSize.height) },
    .variable("canvasSize.width"): { _ in
      Double(UIStylesheetManager.default.canvasSize.width) },
  ]
  private static var exportedConstants: [String: Double] = defaultConstants
  private static var exportedConstantsInitialised: Bool = false

  /// Export this enum into the stylesheet global symbols.
  static public func export(constants: [String: Double]) {
    assert(Thread.isMainThread)
    for (key, value) in constants {
      exportedConstants[key] = value
    }
  }

  /// The default *Expression* builder function.
  public static func builder(_ string: String) -> Expression {
    if !UIStylesheetExpression.exportedConstantsInitialised {
      UIStylesheetExpression.exportedConstantsInitialised = true
      NSTextAlignment.export()
      NSLineBreakMode.export()
      UIImageOrientation.export()
      UIImageResizingMode.export()
    }
    return Expression(string,
                      options: [Expression.Options.boolSymbols, Expression.Options.pureSymbols],
                      constants: UIStylesheetExpression.exportedConstants,
                      symbols: UIStylesheetExpression.defaultSymbols)
  }
}

/// Warning message related to stylesheet parsing and rules evaluation.
@inline(__always) func warn(_ message: String) {
  print("warning \(#function): \(message)")
}

// MARK: - UIStylesheetRepresentableEnum

public protocol UIStylesheetRepresentableEnum {
  /// Every *UIStylesheetRepresentableEnum* must be backed by an integer store.
  init?(rawValue: Int)
  /// Returns every enum value as a map between a 'key' and its integer representation.
  static func expressionConstants() -> [String: Double]
}

public extension UIStylesheetRepresentableEnum {
  /// Export this enum into the stylesheet global symbols.
  static func export() {
    UIStylesheetExpression.export(constants: expressionConstants())
  }
}

// MARK: - UIStylesheetRepresentableEnum Common

extension NSTextAlignment: UIStylesheetRepresentableEnum {
  public static func expressionConstants() -> [String : Double] {
    let namespace = "NSTextAlignment"
    return [
      "\(namespace).left": Double(NSTextAlignment.left.rawValue),
      "\(namespace).center": Double(NSTextAlignment.center.rawValue),
      "\(namespace).right": Double(NSTextAlignment.right.rawValue),
      "\(namespace)t.justified": Double(NSTextAlignment.justified.rawValue),
      "\(namespace).natural": Double(NSTextAlignment.natural.rawValue)]
  }
}

extension NSLineBreakMode: UIStylesheetRepresentableEnum {
  public static func expressionConstants() -> [String : Double] {
    let namespace = "NSLineBreakMode"
    return [
      "\(namespace).byWordWrapping": Double(NSLineBreakMode.byWordWrapping.rawValue),
      "\(namespace).byCharWrapping": Double(NSLineBreakMode.byCharWrapping.rawValue),
      "\(namespace).byClipping": Double(NSLineBreakMode.byClipping.rawValue),
      "\(namespace).byTruncatingHead": Double(NSLineBreakMode.byTruncatingHead.rawValue),
      "\(namespace).byTruncatingMiddle": Double(NSLineBreakMode.byTruncatingMiddle.rawValue)]
  }
}

extension UIImageOrientation: UIStylesheetRepresentableEnum {
  public static func expressionConstants() -> [String : Double] {
    let namespace = "UIImageOrientation"
    return [
      "\(namespace).up": Double(UIImageOrientation.up.rawValue),
      "\(namespace).down": Double(UIImageOrientation.down.rawValue),
      "\(namespace).left": Double(UIImageOrientation.left.rawValue),
      "\(namespace).right": Double(UIImageOrientation.right.rawValue),
      "\(namespace).upMirrored": Double(UIImageOrientation.upMirrored.rawValue),
      "\(namespace).downMirrored": Double(UIImageOrientation.downMirrored.rawValue),
      "\(namespace).leftMirrored": Double(UIImageOrientation.leftMirrored.rawValue),
      "\(namespace).rightMirrored": Double(UIImageOrientation.rightMirrored.rawValue)]
  }
}

extension UIImageResizingMode: UIStylesheetRepresentableEnum {
  public static func expressionConstants() -> [String : Double] {
    let namespace = "UIImageResizingMode"
    return [
      "\(namespace).title": Double(UIImageResizingMode.tile.rawValue),
      "\(namespace).stretch": Double(UIImageResizingMode.stretch.rawValue)]
  }
}
