let cases: [(Bool, Int, DeviceAdditionPolicy.Route)] = [
    (true, 0, .manual),
    (true, 1, .discovered),
    (true, 2, .chooseDevice),
    (true, 5, .chooseDevice),
    (false, 0, .unavailable),
    (false, 1, .unavailable),
    (false, 5, .unavailable)
]
for (canAdd, count, expected) in cases {
    precondition(DeviceAdditionPolicy.route(canAdd: canAdd, discoveredCount: count) == expected)
}
print("Device addition flow: \(cases.count) passed, 0 failed")
