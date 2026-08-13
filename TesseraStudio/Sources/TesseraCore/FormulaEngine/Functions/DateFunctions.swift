//===----------------------------------------------------------------------===//
//  DateFunctions.swift
//  Tessera Formula Engine
//
//  Date arithmetic a schedule needs: EDATE / EOMONTH for rolling a
//  period forward, YEARFRAC for day-count conventions, and
//  WORKDAY / NETWORKDAYS for business-day counting.
//===----------------------------------------------------------------------===//

import Foundation

// MARK: - Date coercion

enum DateArgs {
    /// The calendar used for all date arithmetic.
    ///
    /// `Calendar.current` matches the existing `DATE` implementation, so
    /// a date built by `DATE` round-trips through these functions. It
    /// does make results locale/timezone-dependent, which is worth
    /// revisiting engine-wide rather than only here.
    static var calendar: Calendar { Calendar.current }

    /// Accept either a real date or an Excel serial number.
    static func date(_ value: Value) -> Date? {
        if case .date(let d) = value { return d }
        guard let serial = value.asNumber else { return nil }
        // Excel serial 25569 is 1970-01-01.
        return Date(timeIntervalSince1970: (serial - 25569) * 86400)
    }

    static func components(_ date: Date) -> (year: Int, month: Int, day: Int) {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return (c.year ?? 1900, c.month ?? 1, c.day ?? 1)
    }

    /// Whole days between two dates, ignoring any time component.
    static func dayCount(from start: Date, to end: Date) -> Int {
        let s = calendar.startOfDay(for: start)
        let e = calendar.startOfDay(for: end)
        return calendar.dateComponents([.day], from: s, to: e).day ?? 0
    }

    static func isWeekend(_ date: Date) -> Bool {
        // Calendar weekday: 1 = Sunday, 7 = Saturday.
        let weekday = calendar.component(.weekday, from: date)
        return weekday == 1 || weekday == 7
    }

    /// Holiday list flattened to start-of-day for comparison.
    static func holidaySet(_ value: Value?) -> Set<Date> {
        guard let value else { return [] }
        let entries = ColumnSlice.flattenArrays([value])
        return Set(entries.compactMap { date($0).map { calendar.startOfDay(for: $0) } })
    }
}

// MARK: - Registration

extension FunctionRegistry {

    func registerDateExtended() {
        registerMonthArithmetic()
        registerYearFrac()
        registerBusinessDays()
    }

    // MARK: EDATE / EOMONTH

    private func registerMonthArithmetic() {
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "EDATE",
                description: "The date a number of months before or after a start date.",
                parameters: [
                    FunctionParameter(name: "start_date", acceptsRange: false),
                    FunctionParameter(name: "months", acceptsRange: false),
                ]
            ),
            arity: 2...2,
            call: { args in
                if let e = FunctionArgs.firstError(args) { return .error(e) }
                guard let start = DateArgs.date(args[0]),
                      let months = FunctionArgs.number(args[1]) else { return .error(.notAvailable) }
                guard let result = DateArgs.calendar.date(byAdding: .month, value: Int(months), to: start) else {
                    return .error(.numberInvalid)
                }
                return .date(result)
            }
        ))

        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "EOMONTH",
                description: "The last day of the month a number of months from a start date.",
                parameters: [
                    FunctionParameter(name: "start_date", acceptsRange: false),
                    FunctionParameter(name: "months", acceptsRange: false),
                ]
            ),
            arity: 2...2,
            call: { args in
                if let e = FunctionArgs.firstError(args) { return .error(e) }
                guard let start = DateArgs.date(args[0]),
                      let months = FunctionArgs.number(args[1]) else { return .error(.notAvailable) }
                let calendar = DateArgs.calendar
                guard let shifted = calendar.date(byAdding: .month, value: Int(months), to: start),
                      let monthRange = calendar.range(of: .day, in: .month, for: shifted) else {
                    return .error(.numberInvalid)
                }
                var comps = calendar.dateComponents([.year, .month], from: shifted)
                comps.day = monthRange.count
                guard let result = calendar.date(from: comps) else { return .error(.numberInvalid) }
                return .date(result)
            }
        ))
    }

    // MARK: YEARFRAC

    private func registerYearFrac() {
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "YEARFRAC",
                description: "The fraction of a year between two dates.",
                parameters: [
                    FunctionParameter(name: "start_date", acceptsRange: false),
                    FunctionParameter(name: "end_date", acceptsRange: false),
                    FunctionParameter(name: "basis", description: "0 US 30/360, 1 actual/actual, 2 actual/360, 3 actual/365, 4 European 30/360.", acceptsRange: false, optional: true),
                ]
            ),
            arity: 2...3,
            call: { args in
                if let e = FunctionArgs.firstError(args) { return .error(e) }
                guard var start = DateArgs.date(args[0]),
                      var end = DateArgs.date(args[1]) else { return .error(.notAvailable) }
                let basis = args.count > 2 ? Int(FunctionArgs.number(args[2]) ?? 0) : 0
                guard (0...4).contains(basis) else { return .error(.numberInvalid) }
                // Excel treats the span as unsigned.
                if start > end { swap(&start, &end) }

                switch basis {
                case 0: return .number(thirty360(start: start, end: end, european: false))
                case 4: return .number(thirty360(start: start, end: end, european: true))
                case 2: return .number(Double(DateArgs.dayCount(from: start, to: end)) / 360.0)
                case 3: return .number(Double(DateArgs.dayCount(from: start, to: end)) / 365.0)
                default: return .number(actualActual(start: start, end: end))
                }
            }
        ))
    }

    // MARK: WORKDAY / NETWORKDAYS

    private func registerBusinessDays() {
        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "WORKDAY",
                description: "The date a number of working days from a start date.",
                parameters: [
                    FunctionParameter(name: "start_date", acceptsRange: false),
                    FunctionParameter(name: "days", acceptsRange: false),
                    FunctionParameter(name: "holidays", optional: true),
                ]
            ),
            arity: 2...3,
            call: { args in
                if let e = FunctionArgs.firstError(args) { return .error(e) }
                guard let start = DateArgs.date(args[0]),
                      let rawDays = FunctionArgs.number(args[1]) else { return .error(.notAvailable) }
                let holidays = DateArgs.holidaySet(args.count > 2 ? args[2] : nil)
                let calendar = DateArgs.calendar
                let step = rawDays >= 0 ? 1 : -1
                var remaining = abs(Int(rawDays))
                var cursor = calendar.startOfDay(for: start)

                // Count only days that are neither weekend nor holiday.
                while remaining > 0 {
                    guard let next = calendar.date(byAdding: .day, value: step, to: cursor) else {
                        return .error(.numberInvalid)
                    }
                    cursor = next
                    if !DateArgs.isWeekend(cursor) && !holidays.contains(cursor) {
                        remaining -= 1
                    }
                }
                return .date(cursor)
            }
        ))

        register(BuiltInFunction(
            signature: FunctionSignature(
                name: "NETWORKDAYS",
                description: "The number of working days between two dates, inclusive.",
                parameters: [
                    FunctionParameter(name: "start_date", acceptsRange: false),
                    FunctionParameter(name: "end_date", acceptsRange: false),
                    FunctionParameter(name: "holidays", optional: true),
                ]
            ),
            arity: 2...3,
            call: { args in
                if let e = FunctionArgs.firstError(args) { return .error(e) }
                guard var start = DateArgs.date(args[0]),
                      var end = DateArgs.date(args[1]) else { return .error(.notAvailable) }
                let holidays = DateArgs.holidaySet(args.count > 2 ? args[2] : nil)
                let calendar = DateArgs.calendar
                // A reversed pair counts negative, as in Excel.
                var sign = 1.0
                if start > end {
                    swap(&start, &end)
                    sign = -1
                }

                var cursor = calendar.startOfDay(for: start)
                let last = calendar.startOfDay(for: end)
                var count = 0
                while cursor <= last {
                    if !DateArgs.isWeekend(cursor) && !holidays.contains(cursor) { count += 1 }
                    guard let next = calendar.date(byAdding: .day, value: 1, to: cursor) else { break }
                    cursor = next
                }
                return .number(sign * Double(count))
            }
        ))
    }
}

// MARK: - Day-count conventions

/// 30/360: every month counts as 30 days, every year as 360. The US and
/// European variants differ only in how they clamp a 31st.
private func thirty360(start: Date, end: Date, european: Bool) -> Double {
    let s = DateArgs.components(start)
    let e = DateArgs.components(end)
    var d1 = s.day
    var d2 = e.day

    if european {
        if d1 == 31 { d1 = 30 }
        if d2 == 31 { d2 = 30 }
    } else {
        if d1 == 31 { d1 = 30 }
        // US convention only clamps the end day when the start was
        // already at (or clamped to) 30.
        if d2 == 31 && d1 >= 30 { d2 = 30 }
    }

    let days = (e.year - s.year) * 360 + (e.month - s.month) * 30 + (d2 - d1)
    return Double(days) / 360.0
}

/// Actual/actual: real elapsed days over the real year length. For a
/// span of a year or less the denominator is 366 when the period covers
/// a 29 February, otherwise 365.
private func actualActual(start: Date, end: Date) -> Double {
    let calendar = DateArgs.calendar
    let days = DateArgs.dayCount(from: start, to: end)
    guard days > 0 else { return 0 }

    let startYear = DateArgs.components(start).year
    let endYear = DateArgs.components(end).year
    if startYear == endYear || days <= 366 {
        let containsLeapDay = (startYear...endYear).contains { year in
            var comps = DateComponents()
            comps.year = year
            comps.month = 2
            comps.day = 29
            guard let feb29 = calendar.date(from: comps) else { return false }
            // `date(from:)` rolls 29 Feb into 1 March in a common year.
            guard DateArgs.components(feb29).month == 2 else { return false }
            return feb29 >= calendar.startOfDay(for: start) && feb29 <= calendar.startOfDay(for: end)
        }
        return Double(days) / (containsLeapDay ? 366.0 : 365.0)
    }

    // Multi-year spans use the average year length over the range.
    let years = Double(endYear - startYear + 1)
    var totalDays = 0.0
    for year in startYear...endYear {
        var comps = DateComponents()
        comps.year = year
        comps.month = 1
        comps.day = 1
        guard let jan1 = calendar.date(from: comps),
              let range = calendar.range(of: .day, in: .year, for: jan1) else { continue }
        totalDays += Double(range.count)
    }
    let averageYear = totalDays / years
    return Double(days) / averageYear
}
