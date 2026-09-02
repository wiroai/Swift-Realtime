/// A weak back-reference for callbacks wired during `init`.
///
/// A service hands its helpers closures before `self` is fully
/// initialised and may not capture it yet. The closures capture this
/// box instead, and the service fills it in as its last step; the
/// helpers never keep the service alive.
final class WeakOwner<Owner: AnyObject>: @unchecked Sendable {
    weak var owner: Owner?
}
