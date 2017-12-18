import UIKit

// MARK: - UIStylesheet

public protocol UIStyleProtocol {
  /// The full path for this style {NAMESPACE.STYLE(.MODIFIER)?}.
  var styleIdentifier: String { get }
  /// Applies this style to the view passed as argument.
  /// - Note: Non KVC-compliant keys are skipped.
  func apply(to view: UIView)
}

extension UIStyleProtocol {
  /// Returns the identifier for this style with the desired modifier (analogous to a pseudo
  /// selector in CSS).
  /// - Note: If the condition passed as argument is false *UINilStyle* is returned.
  public func byApplyingModifier(named name: String,
                                 when condition: Bool = true) -> UIStyleProtocol {
    return condition ? "\(styleIdentifier).\(name)" : UINilStyle.nil
  }
  /// Returns this style if the conditioned passed as argument is 'true', *UINilStyle* otherwise.
  public func when(_ condition: Bool) -> UIStyleProtocol {
    return condition ? self : UINilStyle.nil
  }
}

public protocol UIStylesheet: UIStyleProtocol {
  /// The name of the stylesheet rule.
  var rawValue: String { get }
  /// The style name.
  static var styleIdentifier: String { get }
}

public extension UIStylesheet {
  /// The style name.
  public var styleIdentifier: String {
    return Self.styleIdentifier
  }
  /// Returns the rule associated to this stylesheet enum.
  public var rule: UIStylesheetRule {
    guard let rule = UIStylesheetManager.default.rule(style: Self.styleIdentifier,
                                                      name: rawValue) else {
      fatalError("Unable to resolve rule \(Self.styleIdentifier).\(rawValue).")
    }
    return rule
  }
  /// Convenience getter for *UIStylesheetRule.integer*.
  public var integer: Int {
    return rule.integer
  }
  /// Convenience getter for *UIStylesheetRule.cgFloat*.
  public var cgFloat: CGFloat {
    return rule.cgFloat
  }
  /// Convenience getter for *UIStylesheetRule.bool*.
  public var bool: Bool {
    return rule.bool
  }
  /// Convenience getter for *UIStylesheetRule.font*.
  public var font: UIFont {
    return rule.font
  }
  /// Convenience getter for *UIStylesheetRule.color*.
  public var color: UIColor {
    return rule.color
  }
  /// Convenience getter for *UIStylesheetRule.string*.
  public var string: String {
    return rule.string
  }
  /// Convenience getter for *UIStylesheetRule.object*.
  public var object: AnyObject? {
    return rule.object
  }
  /// Convenience getter for *UIStylesheetRule.enum*.
  public func `enum`<T: UIStylesheetRepresentableEnum>(_ type: T.Type,
                                                       default: T = T.init(rawValue: 0)!) -> T {
    return rule.enum(type, default: `default`)
  }

  public func apply(to view: UIView) {
    Self.apply(to: view)
  }
  /// Applies the stylesheet to the view passed as argument.
  public static func apply(to view: UIView) {
    UIStyle.apply(name: Self.styleIdentifier, to: view)
  }
}

extension String: UIStyleProtocol {
  /// The full path for the style {NAMESPACE.STYLE(.MODIFIER)?}.
  public var styleIdentifier: String {
    return self
  }
  /// Applies this style to the view passed as argument.
  public func apply(to view: UIView) {
    UIStyle.apply(name: self, to: view)
  }
}

public struct UIStyle {
  /// Applies this style to the view passed as argument.
  /// - Note: Non KVC-compliant keys are skipped.
  public static func apply(name: String, to view: UIView) {
    guard let defs = UIStylesheetManager.default.defs[name] else {
      fatalError("Unable to resolve definition named \(name).")
    }
    var bridgeDictionary: [String: Any] = [:]
    for (key, value) in defs {
      bridgeDictionary[key] = value.object
    }
    let transitions = UIStylesheetManager.default.animators[name] ?? [:]
    YGSet(view, bridgeDictionary, transitions)
  }
  /// Returns a style identifier in the format NAMESPACE.STYLE(.MODIFIER)?.
  public static func make(_ namespace: String,
                          _ style: String,
                          _ modifier: String? = nil) -> String {
    return "\(namespace).\(style)\(modifier != nil ? ".\(modifier!)" : "")"
  }
}

public class UINilStyle: UIStyleProtocol {
  public static let `nil` = UINilStyle()
  /// - Note: 'nil' is the identifier for a *UINilStyle*.
  public var styleIdentifier: String {
    return "nil"
  }
  /// No operation.
  public func apply(to view: UIView) { }
}
