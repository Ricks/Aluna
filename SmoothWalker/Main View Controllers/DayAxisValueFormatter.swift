//
//  DayAxisValueFormatter.swift
//  ChartsDemo-iOS
//
//  Created by Jacob Christie on 2017-07-09.
//  Copyright © 2017 jc. All rights reserved.
//

import Foundation
import Charts

public class DayAxisValueFormatter: NSObject, AxisValueFormatter {
    var startDate: Date!
    var period: Period = .week
    let dateFormatter = DateFormatter()

    init(startDate: Date) {
        self.startDate = startDate
    }
    
    public func stringForValue(_ value: Double, axis: AxisBase?) -> String {
        let date = startDate + value * 3600 * 24
        switch period {
        case .day:
            dateFormatter.dateFormat = "EEE, MMM d"
        case .week, .month:
            dateFormatter.dateFormat = "MMM d"
        }
        return dateFormatter.string(from: date)
    }

}
