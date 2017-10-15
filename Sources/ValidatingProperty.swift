import Result

private typealias _Result = Result

/// A mutable property that validates mutations before committing them.
///
/// If the property wraps an arbitrary mutable property, changes originated from
/// the inner property are monitored, and would be automatically validated.
/// Note that these would still appear as committed values even if they fail the
/// validation.
///
/// ```
/// let root = MutableProperty("Valid")
/// let outer = ValidatingProperty(root) {
///   $0 == "Valid" ? .valid : .invalid(.outerInvalid)
/// }
///
/// outer.result.value        // `.valid("Valid")
///
/// root.value = "🎃"
/// outer.result.value        // `.invalid("🎃", .outerInvalid)`
/// ```
public final class ValidatingProperty<Value, ValidationError: Swift.Error>: MutablePropertyProtocol {
	fileprivate struct RuleGroup: Hashable {
		let keyPath: PartialKeyPath<Value>?

		var hashValue: Int {
			return keyPath?.hashValue ?? 0
		}

		init(keyPath: PartialKeyPath<Value>? = nil) {
			self.keyPath = keyPath
		}

		static func ==(left: RuleGroup, right: RuleGroup) -> Bool {
			return left.keyPath == right.keyPath
		}
	}

	private enum Mode {
		/// The Rules mode does not support `coerced` decisions, but allows multiple
		/// declarative rules.
		case rules([RuleGroup: [Rule]])

		/// The Validator mode supports `coerced` decisions, but only one rule can be
		/// specified.
		case validator((Value) -> Decision)

		var rules: [RuleGroup: [Rule]]? {
			switch self {
			case let .rules(rules):
				return rules
			case .validator:
				return nil
			}
		}
	}

	private enum SetterInput {
		case full(Value)
		case partial((Value) -> Value)
		case keyPathUpdate(PartialKeyPath<Value>, (Value) -> Value, Failure?)
	}

	private let getter: () -> Value
	private let setter: (SetterInput) -> Void
	private let mode: Mode

	/// The result of the last attempted edit of the root property.
	public let result: Property<Result>

	/// The current value of the property.
	///
	/// The value could have failed the validation. Refer to `result` for the
	/// latest validation result.
	public var value: Value {
		get { return getter() }
		set { setter(.full(newValue)) }
	}

	/// A producer for Signals that will send the property's current value,
	/// followed by all changes over time, then complete when the property has
	/// deinitialized.
	public let producer: SignalProducer<Value, NoError>

	/// A signal that will send the property's changes over time,
	/// then complete when the property has deinitialized.
	public let signal: Signal<Value, NoError>

	/// The lifetime of the property.
	public let lifetime: Lifetime

	private init<Inner: ComposableMutablePropertyProtocol>(_ inner: Inner, mode: Mode) where Inner.Value == Value {
		getter = { inner.value }
		producer = inner.producer
		signal = inner.signal
		lifetime = inner.lifetime
		self.mode = mode

		func validate(_ value: Value) -> Result {
			switch mode {
			case let .rules(groupedRules):
				let decisions = Dictionary(uniqueKeysWithValues: groupedRules
					.map { group, rules -> (RuleGroup, [BinaryDecision]) in
						let errors = rules.map { rule -> BinaryDecision in
							switch rule.backing {
							case let .keyPath(keyPath, validator):
								return validator(value[keyPath: keyPath])
							case let .root(validator):
								return validator(value)
							}
						}
						return (group, errors)
					})
				return Result(value, decisions)
			case let .validator(validator):
				return Result(value, validator(value))
			}
		}

		// This flag temporarily suspends the monitoring on the inner property for
		// writebacks that are triggered by successful validations.
		var isSettingInnerValue = false

		(result, setter) = inner.withValue { initial in
			let mutableResult = MutableProperty(validate(initial))

			mutableResult <~ inner.signal
				.filter { _ in !isSettingInnerValue }
				.map(validate)

			return (Property(capturing: mutableResult), { input in
				// Acquire the lock of `inner` to ensure no modification happens until
				// the validation logic here completes.
				inner.withValue { value in
					func writeback(_ value: Value) {
						isSettingInnerValue = true
						inner.value = value
						isSettingInnerValue = false
					}

					let realInput: Value

					switch input {
					case let .full(value):
						realInput = value
					case let .partial(modifier):
						realInput = modifier(value)
					case let .keyPathUpdate(keyPath, modifier, errors):
						realInput = modifier(value)

						mutableResult.modify { result in
							result = result.updating(keyPath, value: realInput, errors: errors)
						}

						if errors == nil {
							writeback(realInput)
						}

						return
					}

					let writebackValue: Value? = mutableResult.modify { result in
						result = validate(realInput)
						return result.value
					}

					if let value = writebackValue {
						writeback(value)
					}
				}
			})
		}
	}

	/// Create a `ValidatingProperty` that presents a mutable validating
	/// view for an inner mutable property.
	///
	/// The proposed value is only committed when any mutation passes the specified rules.
	///
	/// - note: `inner` is retained by the created property.
	///
	/// - parameters:
	///   - initial: The initial value of the property. It is not required to
	///              pass the validation as specified by `validator`.
	///   - rules: The validation rules to evaluate on any proposed value.
	public convenience init(_ initial: Value, rules: [Rule]) {
		self.init(MutableProperty(initial), rules: rules)
	}

	/// Create a `ValidatingProperty` that presents a mutable validating
	/// view for an inner mutable property.
	///
	/// The proposed value is only committed when any mutation passes the specified rules.
	///
	/// - note: `inner` is retained by the created property.
	///
	/// - parameters:
	///   - inner: The inner property which validated values are committed to.
	///   - rules: The validation rules to evaluate on any proposed value.
	public convenience init<Inner: ComposableMutablePropertyProtocol>(_ inner: Inner, rules: [Rule]) where Inner.Value == Value {
		let groupedRules = Dictionary(grouping: rules, by: { $0.group })
		self.init(inner, mode: .rules(groupedRules))
	}

	/// Create a `ValidatingProperty` that presents a mutable validating
	/// view for an inner mutable property.
	///
	/// The proposed value is only committed when `valid` is returned by the
	/// `validator` closure.
	///
	/// - note: `inner` is retained by the created property.
	///
	/// - parameters:
	///   - inner: The inner property which validated values are committed to.
	///   - validator: The closure to invoke for any proposed value to `self`.
	public convenience init<Inner: ComposableMutablePropertyProtocol>(
		_ inner: Inner,
		_ validator: @escaping (Value) -> Decision
	) where Inner.Value == Value {
		self.init(inner, mode: .validator(validator))
	}

	/// Create a `ValidatingProperty` that validates mutations before
	/// committing them.
	///
	/// The proposed value is only committed when `valid` is returned by the
	/// `validator` closure.
	///
	/// - parameters:
	///   - initial: The initial value of the property. It is not required to
	///              pass the validation as specified by `validator`.
	///   - validator: The closure to invoke for any proposed value to `self`.
	public convenience init(
		_ initial: Value,
		_ validator: @escaping (Value) -> Decision
	) {
		self.init(MutableProperty(initial), mode: .validator(validator))
	}

	/// Create a `ValidatingProperty` that presents a mutable validating
	/// view for an inner mutable property.
	///
	/// The proposed value is only committed when `valid` is returned by the
	/// `validator` closure.
	///
	/// - note: `inner` is retained by the created property.
	///
	/// - parameters:
	///   - inner: The inner property which validated values are committed to.
	///   - other: The property that `validator` depends on.
	///   - validator: The closure to invoke for any proposed value to `self`.
	public convenience init<Other: PropertyProtocol>(
		_ inner: MutableProperty<Value>,
		with other: Other,
		_ validator: @escaping (Value, Other.Value) -> Decision
	) {
		// Capture a copy that reflects `other` without influencing the lifetime of
		// `other`.
		let other = Property(other)

		self.init(inner) { input in
			return validator(input, other.value)
		}

		// When `other` pushes out a new value, the resulting property would react 
		// by revalidating itself with its last attempted value, regardless of
		// success or failure.
		other.signal
			.take(during: lifetime)
			.observeValues { [weak self] _ in
				guard let s = self else { return }

				switch s.result.value {
				case let .invalid(value, _):
					s.value = value

				case let .coerced(_, value, _):
					s.value = value

				case let .valid(value):
					s.value = value
				}
		}
	}

	/// Create a `ValidatingProperty` that validates mutations before
	/// committing them.
	///
	/// The proposed value is only committed when `valid` is returned by the
	/// `validator` closure.
	///
	/// - parameters:
	///   - initial: The initial value of the property. It is not required to
	///              pass the validation as specified by `validator`.
	///   - other: The property that `validator` depends on.
	///   - validator: The closure to invoke for any proposed value to `self`.
	public convenience init<Other: PropertyProtocol>(
		_ initial: Value,
		with other: Other,
		_ validator: @escaping (Value, Other.Value) -> Decision
	) {
		self.init(MutableProperty(initial), with: other, validator)
	}

	/// Create a `ValidatingProperty` that presents a mutable validating
	/// view for an inner mutable property.
	///
	/// The proposed value is only committed when `valid` is returned by the
	/// `validator` closure.
	///
	/// - note: `inner` is retained by the created property.
	///
	/// - parameters:
	///   - inner: The inner property which validated values are committed to.
	///   - other: The property that `validator` depends on.
	///   - validator: The closure to invoke for any proposed value to `self`.
	public convenience init<U, E>(
		_ inner: MutableProperty<Value>,
		with other: ValidatingProperty<U, E>,
		_ validator: @escaping (Value, U) -> Decision
	) {
		self.init(inner, with: other, validator)
	}

	/// Create a `ValidatingProperty` that validates mutations before
	/// committing them.
	///
	/// The proposed value is only committed when `valid` is returned by the
	/// `validator` closure.
	///
	/// - parameters:
	///   - initial: The initial value of the property. It is not required to
	///              pass the validation as specified by `validator`.
	///   - other: The property that `validator` depends on.
	///   - validator: The closure to invoke for any proposed value to `self`.
	public convenience init<U, E>(
		_ initial: Value,
		with other: ValidatingProperty<U, E>,
		_ validator: @escaping (Value, U) -> Decision
	) {
		// Capture only `other.result` but not `other`.
		let otherValidations = other.result

		self.init(initial) { input in
			let otherValue: U

			switch otherValidations.value {
			case let .valid(value):
				otherValue = value

			case let .coerced(_, value, _):
				otherValue = value

			case let .invalid(value, _):
				otherValue = value
			}

			return validator(input, otherValue)
		}

		// When `other` pushes out a new validation result, the resulting property
		// would react by revalidating itself with its last attempted value,
		// regardless of success or failure.
		otherValidations.signal
			.take(during: lifetime)
			.observeValues { [weak self] _ in
				guard let s = self else { return }

				switch s.result.value {
				case let .invalid(value, _):
					s.value = value

				case let .coerced(_, value, _):
					s.value = value

				case let .valid(value):
					s.value = value
				}
			}
	}

	public subscript<U>(keyPath: WritableKeyPath<Value, U>) -> BindingTarget<U> {
		return BindingTarget(on: UIScheduler(), lifetime: lifetime) { [weak self] value in
			guard let strongSelf = self else { return }
			guard let validations = strongSelf.mode.rules?[RuleGroup(keyPath: keyPath)] else {
				// Perform a full validation if the key path is not found.
				strongSelf.setter(.partial { current in
					var new = current
					new[keyPath: keyPath] = value
					return new
				})
				return
			}

			let errors = validations.flatMap { rule in
				(value)
			}

			strongSelf.store.modify { store in
				store.errors[keyPath] = errors.isEmpty ? nil : errors

				if errors.isEmpty {
					store.value[keyPath: keyPath] = value
				}
			}
		}
	}

	public struct Failure: Error {
		private let errors: [RuleGroup: [ValidationError]]
	}

	public struct Rule {
		enum Backing {
			case keyPath(PartialKeyPath<Value>, (Any) -> BinaryDecision)
			case root((Value) -> BinaryDecision)
		}

		let backing: Backing
		fileprivate var group: RuleGroup {
			switch backing {
			case let .keyPath(keyPath, _):
				return RuleGroup(keyPath: keyPath)
			case .root:
				return RuleGroup()
			}
		}

		public init<U>(for keyPath: WritableKeyPath<Value, U>, validate: @escaping (U) -> BinaryDecision) {
			self.backing = .keyPath(keyPath, { validate($0 as! U) })
		}

		public init(validate: @escaping (Value) -> BinaryDecision) {
			self.backing = .root(validate)
		}
	}

	/// Represents a binary decision of a validator of a validating property made on a
	/// proposed value.
	public enum BinaryDecision {
		/// The proposed value is valid.
		case valid

		/// The proposed value is invalid.
		case invalid(ValidationError)
	}

	/// Represents a tenary decision of a validator of a validating property made on a
	/// proposed value.
	public enum Decision {
		/// The proposed value is valid.
		case valid

		/// The proposed value is invalid, but the validator coerces it into a
		/// replacement which it deems valid.
		case coerced(Value, ValidationError?)

		/// The proposed value is invalid.
		case invalid(ValidationError)

		fileprivate init(_ decision: BinaryDecision) {
			guard case let .invalid(error) = decision else {
				self = .valid
				return
			}
			self = .invalid(error)
		}
	}

	/// Represents the result of the validation performed by a validating property.
	public enum Result {
		/// The proposed value is valid.
		case valid(Value)

		/// The proposed value is invalid, but the validator was able to coerce it
		/// into a replacement which it deemed valid.
		case coerced(replacement: Value, proposed: Value, error: Failure)

		/// The proposed value is invalid.
		case invalid(Value, Failure)

		/// Whether the value is invalid.
		public var isInvalid: Bool {
			if case .invalid = self {
				return true
			} else {
				return false
			}
		}

		/// Extract the valid value, or `nil` if the value is invalid.
		public var value: Value? {
			switch self {
			case let .valid(value):
				return value
			case let .coerced(value, _, _):
				return value
			case .invalid:
				return nil
			}
		}

		/// Extract the error if the value is invalid.
		public var error: Failure? {
			if case let .invalid(_, error) = self {
				return error
			} else {
				return nil
			}
		}

		/// Construct the result from a tenary decision.
		fileprivate init(_ proposedValue: Value, _ decision: Decision) {
			switch decision {
			case .valid:
				self = .valid(proposedValue)
			case let .coerced(replacement, error):
				self = .coerced(replacement: replacement,
								proposed: proposedValue,
								error: Failure(errors: [RuleGroup(): [error]]))
			case let .invalid(error):
				self = .invalid(proposedValue, Failure(errors: [RuleGroup(): [error]]))
			}
		}

		/// Construct the result from a validation decision dictionary.
		fileprivate init(_ proposedValue: Value, _ decisions: [RuleGroup: [BinaryDecision]]) {
			let errors = Dictionary(uniqueKeysWithValues: decisions
				.mapValues { decisions -> [ValidationError] in
					return decisions.flatMap { decision in
						guard case let .invalid(error) = decision else { return nil }
						return error
					}
				}
				.filter { !$0.value.isEmpty })

			guard errors.isEmpty else {
				self = .valid(proposedValue)
				return
			}

			self = .invalid(proposedValue, Failure(errors: errors))
		}

		/// Construct a new result by updating the given key path.
		fileprivate func updating(_ keyPath: PartialKeyPath<Value>, value: Value, errors: Failure?) -> Result {
			switch (self, errors) {
			case (.valid, .none):
				return .valid(value)
			case (.coerced, _):
				fatalError()
				case let (.invalid(_, oldFailure))
			}
		}
	}
}
