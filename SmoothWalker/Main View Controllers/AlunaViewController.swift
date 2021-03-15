//
//  AlunaViewController.swift
//  Aluna Demo
//
//  Created by Richard Clark on 3/12/21.
//

import UIKit
import Charts
import HealthKit

class AlunaViewController: UIViewController, ChartViewDelegate, HealthQueryDataSource {

    @IBOutlet var barChartView: BarChartView!
    @IBOutlet var periodSelector: UISegmentedControl!
    var valueFormatter: DayAxisValueFormatter!
    var startDate = Date() {
        didSet {
            valueFormatter = DayAxisValueFormatter(startDate: startDate)
            valueFormatter.period = period
        }
    }
    var period: Period = .week
    let queryAnchor: HKQueryAnchor? = nil
    let queryLimit: Int = HKObjectQueryNoLimit
    var queryPredicate: NSPredicate?
    let dataTypeIdentifier = HKQuantityTypeIdentifier.sixMinuteWalkTestDistance.rawValue
    var dataValues = [HealthDataTypeValue]()
    var values = [BarChartDataEntry]() {
        didSet {
            let set = BarChartDataSet(entries: values, label: "Speed (mph)")
            barChartView.data = BarChartData(dataSet: set)
            let formatter = NumberFormatter()
            formatter.minimumFractionDigits = 2
            formatter.maximumFractionDigits = 2
            barChartView.data?.setValueFormatter(DefaultValueFormatter(formatter: formatter))
            setPeriodZoom(period)
        }
    }
    let metersPerMile = 1609.34

    // MARK: Initializers

    init() {
        super.init(nibName: "AlunaViewController", bundle: Bundle.main)
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
    }

    // MARK: View Life Cycle Overrides

    override func viewDidLoad() {
        super.viewDidLoad()
        fetchData()

        var components = DateComponents()
        components.day = 1
        components.month = 1
        components.year = 2020
        components.hour = 0
        components.minute = 0
        valueFormatter = DayAxisValueFormatter(startDate: startDate)

        barChartView.scaleXEnabled = true
        barChartView.scaleYEnabled = false
        barChartView.delegate = self

        let leftAxis = barChartView.leftAxis
        leftAxis.drawGridLinesEnabled = false
        leftAxis.drawAxisLineEnabled = false
        leftAxis.drawLabelsEnabled = false
        leftAxis.drawZeroLineEnabled = true
        leftAxis.axisMinimum = 0.0

        let rightAxis = barChartView.rightAxis
        rightAxis.drawGridLinesEnabled = false
        rightAxis.drawAxisLineEnabled = false
        rightAxis.drawLabelsEnabled = false

        let xAxis = barChartView.xAxis
        xAxis.drawGridLinesEnabled = false
        xAxis.labelPosition = .bottom
        xAxis.drawLabelsEnabled = true
        xAxis.valueFormatter = valueFormatter
        xAxis.granularityEnabled = true

        periodSelector.selectedSegmentIndex = period.rawValue
        setPeriodZoom(period)
        setPeriodChartAttrs(period)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)

        // Authorization
        if !dataValues.isEmpty { return }

        HealthData.requestHealthDataAccessIfNeeded(dataTypes: [dataTypeIdentifier]) { (success) in
            if success {
                // Perform the query and reload the data.
                self.fetchData()
            }
        }
    }

    // MARK: - Network

    private func fetchData() {
        Network.pull() { [weak self] (serverResponse) in
            self?.queryPredicate = createLastYearPredicate(from: serverResponse.date)
            self?.handleServerResponse(serverResponse)
        }
    }

    /// Handle a response fetched from a remote server. This function will also save any HealthKit samples and update the UI accordingly.
    func handleServerResponse(_ serverResponse: ServerResponse) {
        let weeklyReport = serverResponse.weeklyReport
        let addedSamples = weeklyReport.samples.map { (serverHealthSample) -> HKQuantitySample in

            // Set the sync identifier and version
            var metadata = [String: Any]()
            let sampleSyncIdentifier = String(format: "%@_%@", weeklyReport.identifier, serverHealthSample.syncIdentifier)

            metadata[HKMetadataKeySyncIdentifier] = sampleSyncIdentifier
            metadata[HKMetadataKeySyncVersion] = serverHealthSample.syncVersion

            // Create HKQuantitySample
            let quantity = HKQuantity(unit: .meter(), doubleValue: serverHealthSample.value)
            let sampleType = HKQuantityType.quantityType(forIdentifier: .sixMinuteWalkTestDistance)!
            let quantitySample = HKQuantitySample(type: sampleType,
                                                  quantity: quantity,
                                                  start: serverHealthSample.startDate,
                                                  end: serverHealthSample.endDate,
                                                  metadata: metadata)

            return quantitySample
        }

        HealthData.healthStore.save(addedSamples) { (success, error) in
            if success {
                self.loadData()
            }
        }
    }

    // MARK: HealthQueryDataSource

    /// Perform a query and reload the data upon completion.
    func loadData() {
        performQuery {
            DispatchQueue.main.async { [weak self] in
                self?.reloadData()
            }
        }
    }

    func performQuery(completion: @escaping () -> Void) {
        guard let sampleType = getSampleType(for: dataTypeIdentifier) else { return }

        let anchoredObjectQuery = HKAnchoredObjectQuery(type: sampleType,
                                                        predicate: queryPredicate,
                                                        anchor: queryAnchor,
                                                        limit: queryLimit) {
            (query, samplesOrNil, deletedObjectsOrNil, anchor, errorOrNil) in

            guard let samples = samplesOrNil else { return }

            self.dataValues = samples.map { (sample) -> HealthDataTypeValue in
                var dataValue = HealthDataTypeValue(startDate: sample.startDate,
                                                    endDate: sample.endDate,
                                                    value: .zero)
                if let quantitySample = sample as? HKQuantitySample,
                   let unit = preferredUnit(for: quantitySample) {
                    dataValue.value = quantitySample.quantity.doubleValue(for: unit)
                }

                return dataValue
            }

            completion()
        }

        HealthData.healthStore.execute(anchoredObjectQuery)
    }

    func reloadData() {
        DispatchQueue.main.async {
            var vals = [BarChartDataEntry]()
            if self.dataValues.count == 0 {
                self.startDate = Date()
            } else {
                self.startDate = self.dataValues[0].startDate
                for dataValue in self.dataValues {
                    let days = dataValue.startDate.timeIntervalSince(self.startDate) / (3600 * 24)
                    vals.append(BarChartDataEntry(x: days,
                                                  y: dataValue.value * 10 / self.metersPerMile))
                }
            }
            self.values = vals
        }
    }

    // MARK: Private functions

    private func zoomTo(n: Int) {   // Zoom to show n values
        var desiredScaleX: CGFloat = 1.0
        let leftX = barChartView.lowestVisibleX
        let rightX = barChartView.highestVisibleX
        let centerX = (leftX + rightX) / 2.0
        if n < values.count {
            desiredScaleX = CGFloat(values.count + 1) / (CGFloat(n) + 0.4)
        }
        print("n = \(n), desiredScaleX = \(desiredScaleX)")
        barChartView.zoomAndCenterViewAnimated(scaleX: desiredScaleX,
                                               scaleY: 1.0,
                                               xValue: round(centerX),
                                               yValue: 0.0,
                                               axis: .left,
                                               duration: 0.5)
    }

    private func setPeriodZoom(_ period: Period) {
        switch period {
        case .day:
            zoomTo(n: 1)
        case .week:
            zoomTo(n: 7)
        case .month:
            zoomTo(n: 31)
        }
    }

    private func setPeriodChartAttrs(_ period: Period) {
        switch period {
        case .day, .week:
            barChartView.xAxis.granularity = 1
        case .month:
            barChartView.xAxis.granularity = 4
        }
        valueFormatter.period = period
        barChartView.xAxis.valueFormatter = valueFormatter
    }

    // MARK: ChartViewDelegate

    func chartScaled(_ chartView: ChartViewBase, scaleX: CGFloat, scaleY: CGFloat) {
        let daysShown = CGFloat(values.count + 1) / barChartView.scaleX
        let monthDaysShown = min(31, values.count)
        if daysShown < 4.0 {
            setPeriodChartAttrs(.day)
            periodSelector.selectedSegmentIndex = Period.day.rawValue
        } else if daysShown < CGFloat(7 + monthDaysShown) / 2.0 {
            setPeriodChartAttrs(.week)
            periodSelector.selectedSegmentIndex = Period.week.rawValue
        } else {
            setPeriodChartAttrs(.month)
            periodSelector.selectedSegmentIndex = Period.month.rawValue
        }
    }

    // MARK: IBActions

    @IBAction func periodSelected(_ sender: Any) {
        if let period = Period.init(rawValue: periodSelector.selectedSegmentIndex) {
            self.period = period
            setPeriodZoom(period)
            setPeriodChartAttrs(period)
        }
    }

}
