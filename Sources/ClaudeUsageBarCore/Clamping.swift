extension Comparable {
    /// `self` restricted to `range`: the nearer bound when `self` falls
    /// outside it, `self` unchanged otherwise. A floating-point NaN clamps
    /// to the lower bound (`max`/`min` return their second argument when
    /// the comparison with NaN is false).
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(range.upperBound, max(range.lowerBound, self))
    }
}
