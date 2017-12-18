import UIKit

// MARK: - UINodeDelegateProtocol

public protocol UINodeDelegateProtocol: class {
  /// The backing view of *node* just got rendered and added to the view hierarchy.
  /// - parameter view: The view that just got installed in the view hierarchy.
  func nodeDidMount(_ node: UINodeProtocol, view: UIView)
  /// The backing view of *node* is about to be layed out.
  /// - parameter view: The view that is about to be configured and layed out.
  func nodeWillLayout(_ node: UINodeProtocol, view: UIView)
  /// The backing view of *node* just got layed out.
  /// - parameter view: The view that has just been configured and layed out.
  func nodeDidLayout(_ node: UINodeProtocol, view: UIView)
}

// MARK: - UINodeProtocol

public protocol UINodeProtocol: Disposable {
  /// Backing view for this node.
  var renderedView: UIView? { get }
  /// *Optional* delegate.
  weak var delegate: UINodeDelegateProtocol? { get set }
  /// The parent node (if this is not the root node in the hierarchy).
  weak var parent: UINodeProtocol? { get set }
  /// The component that manages this subtree (if applicable).
  weak var associatedComponent: UIComponentProtocol? { get set }
  /// A unique key for the component/node (necessary if the component is stateful).
  var key: String? { get set }
  /// The reuse identifier for this node is its hierarchy.
  /// Identifiers help Render understand which items have changed.
  /// A custom *reuseIdentifier* is mandatory if the node has a custom creation closure.
  var reuseIdentifier: String { get set }
  /// The subnodes of this node.
  var children: [UINodeProtocol] { get }
  /// An additional configuration closure meant to override some of the original configuration
  /// of the node.
  var overrides: ((UIView) -> Void)? { get set }
  /// Re-applies the configuration closure for this node and compute its layout.
  func layout(in bounds: CGSize, options: [UINodeOption])
  /// Mount the component in the view hierarchy by running the *reconciliation algorithm*.
  /// This means that only the required changes to the view hierarchy are going to be applied.
  func reconcile(in view: UIView?, size: CGSize?, options: [UINodeOption])
  /// Returns the node with the key matching the function argument.
  func nodeWithKey(_ key: String) -> UINodeProtocol?
  
  // Internal.

  /// Component that builds components in non-traditional fashion (e.g. table/collection views)
  /// needs to keep track of their children by updating their root nodes 'unmanagedChildren'
  /// at every render pass.
  /// - note: *Internal use only*.
  var unmanagedChildren: [UINodeProtocol] { get set }
  /// This component is the n-th children.
  /// - note: *Internal use only*.
  var index: Int { get set }
  /// String representation of the underlying view type.
  /// - note: *Internal use only*.
  var _debugType: String { get }
  /// String representation of the current state.
  /// - note: *Internal use only*.
  var _debugStateDescription: String { get set }
  /// String representation of the current props.
  /// - note: *Internal use only*.
  var _debugPropDescription: String { get set }
  /// Asks the node to build the backing view for this node.
  /// - note: *Internal use only*.
  func _constructView(with reusableView: UIView?)
  /// Configure the backing view of this node by running the configuration closure provided in the
  /// init method.
  /// - note: *Internal use only*.
  func _setup(in bounds: CGSize, options: [UINodeOption])
  /// Returns all of the keys found in this subtree.
  func _retrieveKeysRecursively() -> Set<String>
}
// MARK: - UINode

public class UINode<V: UIView>: UINodeProtocol {

  public struct Configuration {
    /// The target node for this layout pass.
    public internal(set) var node: UINode<V>
    /// The concrete backing view.
    public internal(set) var view: V
    /// The canvas size for the root componens.
    public internal(set) var canvasSize: CGSize

    init(node: UINode<V>, view: V, size: CGSize) {
      self.node = node
      self.view = view
      self.canvasSize = size
    }

    public func set<T>(_ keyPath: ReferenceWritableKeyPath<V, T>,
                       _ value: T,
                       animator: UIViewPropertyAnimator? = nil) {
      node.viewProperties[keyPath.hashValue] =
          UIViewKeyPathValue(keyPath: keyPath, value: value, animator: animator)
    }
  }

  public typealias CreationClosure = () -> V
  public typealias ConfigurationClosure = (Configuration) -> Void

  public var reuseIdentifier: String
  public fileprivate(set) var renderedView: UIView? = nil
  public fileprivate(set) var children: [UINodeProtocol] = []
  public var _debugType: String
  public var _debugStateDescription: String = ""
  public var _debugPropDescription: String = ""
  public weak var delegate: UINodeDelegateProtocol?
  public weak var parent: UINodeProtocol?
  public weak var associatedComponent: UIComponentProtocol?
  public var key: String? = nil
  public var index: Int = 0
  public var unmanagedChildren: [UINodeProtocol] = []
  public var overrides: ((UIView) -> Void)? = nil

  /// Whether this object has been disposed or not.
  /// Once an object is disposed it cannot be used any longer.
  public var isDisposed: Bool = false

  // Private.

  public var createClosure: CreationClosure
  public var configClosure: ConfigurationClosure = { _ in }
  // 'true' whenever view just got created and added to the view hierarchy.
  private var shouldInvokeDidMount: Bool = false
  // The target object for the view binding method.
  private weak var bindTarget: AnyObject?
  // Optional associated style.
  private var styles: [UIStyleProtocol] = []

  // Internal.

  // The properties for this node.
  var viewProperties: [Int: UIViewKeyPathValue] = [:]

  /// Creates a new immutable UI description node.
  /// - parameter reuseIdentifier: Mandatory if the node has a custom creation closure.
  /// - parameter key: A unique key for the node (necessary if the component is stateful).
  /// - parameter create: Custom view initialization closure.
  /// - parameter configure: This closure is invoked whenever the 'layout' method is invoked.
  /// Configure your backing view by using the *UILayout* object (e.g.):
  /// ```
  /// ... { layout in
  ///   layout.set(\UIView.backgroundColor, value: .green)
  ///   layout.set(\UIView.layer.borderWidth, value: 1)
  /// ```
  /// You can also access to the view directly (this is less performant because the infrastructure
  /// can't keep tracks of these view changes, but necessary when coping with more complex view
  /// configuration methods).
  /// ```
  /// ... { layout in
  ///   layout.view.backgroundColor = .green
  ///   layout.view.setTitle("FOO", for: .normal)
  /// ```
  public init(reuseIdentifier: String? = nil,
              key: String? = nil,
              create: (() -> V)? = nil,
              styles: [UIStyleProtocol] = [],
              configure: ConfigurationClosure? = nil) {
    self.reuseIdentifier = UINodeReuseIdentifierMake(type: V.self, identifier: reuseIdentifier)
    self._debugType =  String(describing: V.self)
    self.createClosure = create ??  { V() }
    if create != nil && reuseIdentifier == _debugType {
      fatalError("Always specify a reuse identifier whenever a custom create closure is provided.")
    }
    self.key = key
    self.styles = styles
    if let configure = configure {
      self.configClosure = configure
    }
  }

  open func configure(_ configClosure: @escaping ConfigurationClosure) {
    self.configClosure = configClosure
  }

  /// Sets the subnodes of this node.
  /// - note: Instances of *UINilNode* are excluded from the node hierarchy.
  @discardableResult public func children(_ nodes: [UINodeProtocol]) -> Self {
    children = []
    var index = 0
    var newChildren: [UINodeProtocol] = []
    for child in nodes {
      if child is UINilNode { continue }
      child.index = index
      child.parent = self
      newChildren.append(child)
      index += 1
    }
    children = newChildren
    return self
  }

  public func _setup(in bounds: CGSize, options: [UINodeOption]) {
    assert(Thread.isMainThread)
    guard !isDisposed else {
      disposedWarning()
      return
    }

    _constructView()
    willLayout(options: options)

    let view = requireRenderedView()
    guard let renderedView = view as? V else {
      print("Unexpected error: View/State/Prop type mismatch.")
      return
    }
    view.renderContext.storeOldGeometryRecursively()

    for style in styles {
      style.apply(to: view)
    }

    let viewConfiguration = Configuration(node: self, view: renderedView, size: bounds)
    configClosure(viewConfiguration)
    overrides?(view)

    // Configure the children recursively.
    for child in children {
      child._setup(in: bounds, options: options)
    }

    let config = view.renderContext
    let oldConfigurationKeys = Set(config.appliedConfiguration.keys)
    let newConfigurationKeys = Set(viewProperties.keys)

    let configurationToRestore = oldConfigurationKeys.filter { propKey in
      !newConfigurationKeys.contains(propKey)
    }
    for propKey in configurationToRestore {
      config.appliedConfiguration[propKey]?.restore(view: view)
    }
    for propKey in newConfigurationKeys {
      viewProperties[propKey]?.assign(view: view)
    }

    if view.yoga.isEnabled, view.yoga.isLeaf, view.yoga.isIncludedInLayout {
      view.frame.size = CGSize.zero
      view.yoga.markDirty()
    }
    didLayout(options: options)
  }

  /// Re-applies the configuration for the node and compute its layout.
  public func layout(in bounds: CGSize, options: [UINodeOption] = []) {
    assert(Thread.isMainThread)
    guard !isDisposed else {
      disposedWarning()
      return
    }

    _setup(in: bounds, options: options)

    let view = requireRenderedView()
    viewProperties = [:]

    func computeLayout() {
      // Compute the flexbox layout for the node.
      view.bounds.size = bounds
      view.yoga.applyLayout(preservingOrigin: false)
      view.bounds.size = view.yoga.intrinsicSize

      view.yoga.applyLayout(preservingOrigin: false)
      view.frame.normalize()
    }

    computeLayout()
    animateLayoutChangesIfNecessary()
  }

  private func animateLayoutChangesIfNecessary() {
    let view = requireRenderedView()
    view.renderContext.storeNewGeometryRecursively()
    if let frameChangeAnimator = associatedComponent?.context?.layoutAnimator {
      view.renderContext.applyOldGeometryRecursively()
      frameChangeAnimator.stopAnimation(true)
      frameChangeAnimator.addAnimations {
        view.renderContext.applyNewGeometryRecursively()
      }
      frameChangeAnimator.startAnimation()
      view.renderContext.fadeInNewlyCreatedViews(delay: frameChangeAnimator.duration)
    }
  }

  private func requireRenderedView() -> UIView {
    guard let view = renderedView else {
      print("Unexpected error: The view is nil.")
      fatalError()
    }
    return view
  }

  private func willLayout(options: [UINodeOption]) {
    let view = requireRenderedView()
    if !options.contains(.preventDelegateCallbacks) {
      // Notify the delegate.
      delegate?.nodeWillLayout(self, view: view)
      associatedComponent?.nodeWillLayout(self, view: view)
    }
  }

  private func didLayout( options: [UINodeOption]) {
    let view = requireRenderedView()
    // Apply some view-specific configuration (e.g. content insets for scrollviews).
    if let UIPostRenderingView = view as? UIPostRendering {
      UIPostRenderingView.postRender()
    }
    if !options.contains(.preventDelegateCallbacks) {
      // Notify the delegate.
      delegate?.nodeDidLayout(self, view: view)
      associatedComponent?.nodeDidLayout(self, view: view)
    }

    /// The view has been newly created.
    if shouldInvokeDidMount {
      shouldInvokeDidMount = false
      delegate?.nodeDidMount(self, view: view)
      associatedComponent?.nodeDidMount(self, view: view)
    }
  }

  /// Asks the node to build the backing view for this node.
  public func _constructView(with reusableView: UIView? = nil) {
    assert(Thread.isMainThread)
    guard !isDisposed else {
      disposedWarning()
      return
    }

    defer {
      bindIfNecessary(renderedView!)
    }
    guard renderedView == nil else { return }
    if let reusableView = reusableView as? V {
      reusableView.renderContext.node = self
      renderedView = reusableView
    } else {
      let view = createClosure()
      shouldInvokeDidMount = true
      view.yoga.isEnabled = true
      view.tag = reuseIdentifier.hashValue
      view.hasNode = true
      view.renderContext.node = self
      renderedView = view
    }
  }

  /// Reconciliation algorithm for the view hierarchy.
  private func _reconcile(node: UINodeProtocol, size: CGSize, view: UIView?, parent: UIView) {
    // The candidate view is a good match for reuse.
    if let view = view, view.hasNode && view.tag == node.reuseIdentifier.hashValue {
      node._constructView(with: view)
      view.renderContext.isNewlyCreated = false
    } else {
      // The view for this node needs to be created.
      view?.removeFromSuperview()
      node._constructView(with: nil)
      node.renderedView!.renderContext.isNewlyCreated = true
      parent.insertSubview(node.renderedView!, at: node.index)
    }

    // Gets all of the existing subviews.
    var oldSubviews = view?.subviews.filter { view in
      return view.hasNode
    }

    for subnode in node.children {
      // Look for a candidate view matching the node.
      let candidateView = oldSubviews?.filter { view in
        return view.tag == subnode.reuseIdentifier.hashValue
      }.first
      // Pops the candidate view from the collection.
      oldSubviews = oldSubviews?.filter {
        view in view !== candidateView
      }
      // Recursively reconcile the subnode.
      _reconcile(node: subnode, size: size, view: candidateView, parent: node.renderedView!)
    }
    // Remove all of the obsolete old views that couldn't be recycled.
    for view in oldSubviews ?? [] {
      view.removeFromSuperview()
    }
  }

  /// Finding the minimal number of modifications between two arbitrary trees is a *O(n^3)* problem.
  /// This isn’t tractable for our use case. Render uses a simple and yet powerful heuristics
  /// to find a very good approximation in *O(n)*.
  /// It only tries to reconcile trees level by level. This drastically reduces the complexity
  /// and isn’t a big loss as it is very rare in applications to have a component being moved
  /// to a different level in the tree.
  public func reconcile(in view: UIView? = nil, size: CGSize? = nil, options: [UINodeOption] = []) {
    assert(Thread.isMainThread)
    guard !isDisposed else {
      disposedWarning()
      return
    }

    guard let view = view ?? renderedView?.superview else {
      return
    }
    let size = size ?? view.bounds.size

    let startTime = CFAbsoluteTimeGetCurrent()
    _reconcile(node: self, size: size, view: view.subviews.first, parent: view)
    layout(in: size, options: options)

    debugReconcileTime("\(Swift.type(of: self)).reconcile", startTime: startTime)
  }

  // Binding closure.
  private var bindIfNecessary: (UIView) -> Void = { _ in }

  /// Binds the rendered view to a property in the target object.
  /// - parameter target: The target object for the binding.
  /// - parameter keyPath: The property path in the target object.
  /// - note: Declare the property in your target as *weak* in order to prevent retain ciclyes.
  public func bindView<O: AnyObject, V>(target: O,
                                        keyPath: ReferenceWritableKeyPath<O, V>) {
    assert(Thread.isMainThread)
    guard !isDisposed else {
      disposedWarning()
      return
    }

    bindTarget = target
    bindIfNecessary = { [weak self] (view: UIView) in
      guard let object = self?.bindTarget as? O, let view = view as? V else {
        return
      }
      object[keyPath: keyPath] = view
    }
  }

  /// Returns the node with the key matching the function argument.
  public func nodeWithKey(_ key: String) -> UINodeProtocol? {
    guard !isDisposed else {
      disposedWarning()
      return nil
    }
    if self.key == key { return self }
    for child in children {
      if let result = child.nodeWithKey(key) {
        return result
      }
    }
    return nil
  }

  /// Returns all of the keys found in this subtree.
  public func _retrieveKeysRecursively() -> Set<String> {
    var keys = Set<String>()
    func retrieveAllKeys(node: UINodeProtocol) {
      if let key = node.key { keys.insert(key) }
      node.children.forEach { node in retrieveAllKeys(node: node) }
      node.unmanagedChildren.forEach { node in retrieveAllKeys(node: node) }
    }
    retrieveAllKeys(node: self)
    return keys
  }

  /// Dispose the object and makes it unusable.
  public func dispose() {
    isDisposed = true
    for child in children { child.dispose() }
    // Clears the closures.
    createClosure = { V() }
    configClosure = { _ in }
    overrides = nil
    // Resets all the targets of the target view.
    renderedView?.resetAllTargets()
    renderedView = nil
    NotificationCenter.default.removeObserver(self)
    children = []
    // This properties are already 'nil' - we wipe them just for sake of consistency.
    bindTarget = nil
    delegate = nil
    parent = nil
    associatedComponent = nil
  }
}

/// Make a reuse identifier string given a type and a custom marker.
public func UINodeReuseIdentifierMake<V>(type: V.Type, identifier: String? = nil) -> String {
  let prefix = String(describing: V.self)
  if let identifier = identifier {
    return "\(prefix)_\(identifier)"
  }
  return prefix
}

// MARK: - UINilNode

/// Represent an empty node.
/// - note: Use this when you want to return an empty child in some conditions.
public class UINilNode: UINode<UIView> {
  static let `nil` = UINilNode()

  public override var reuseIdentifier: String {
    get { return "NilNode" }
    set { }
  }

  private init() {
    super.init(reuseIdentifier: "NilNode")
    NotificationCenter.default.removeObserver(self)
  }
}

// MARK: - UINodeOption

public enum UINodeOption: Int {
  /// Prevent the delegate to be notified at this layout pass.
  case preventDelegateCallbacks
}

func debugReconcileTime(_ label: String, startTime: CFAbsoluteTime, threshold: CFAbsoluteTime = 16){
  let timeElapsed = (CFAbsoluteTimeGetCurrent() - startTime) * 1000
  // - note: 60fps means you need to render a frame every ~16ms to not drop any frames.
  // This is even more important when used inside a cell.
  if timeElapsed > threshold  {
    print(String(format: "\(label) (%2f) ms.", arguments: [timeElapsed]))
  }
}
