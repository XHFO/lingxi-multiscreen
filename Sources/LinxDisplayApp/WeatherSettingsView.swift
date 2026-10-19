import SwiftUI
import LinxDisplayCore

struct WeatherSettingsView: View {
    @ObservedObject var model: AppModel
    @State private var query = ""
    @State private var cities: [WeatherCity] = []
    @State private var searching = false
    @State private var searchStatus = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                TextField("城市名称", text: $query).onSubmit { search() }
                Button("搜索城市") { search() }.disabled(searching || query.trimmingCharacters(in: .whitespaces).isEmpty)
                HelpIcon(text: "通过 Open-Meteo 获取天气。仅发送所选城市坐标，不读取系统定位；不发送设备、Home Assistant 或打印机凭据。天气与建议仅供参考。")
            }
            ForEach(cities) { city in
                Button(city.title) {
                    var value = model.settings.weather
                    value.city = city.name; value.latitude = city.latitude; value.longitude = city.longitude
                    model.settings.weatherSnapshot = nil; model.settings.weather = value
                    cities = []; Task { await model.refreshWeather() }
                }.buttonStyle(.borderless)
            }
            if !searchStatus.isEmpty { Text(searchStatus).foregroundStyle(.secondary) }
            LabeledContent("当前城市", value: model.settings.weather.city.isEmpty ? "尚未选择" : model.settings.weather.city)
            Stepper("更新间隔：\(model.settings.weather.refreshMinutes) 分钟", value: $model.settings.weather.refreshMinutes, in: 15...180, step: 15)
            HStack {
                Button("更新天气") { Task { await model.refreshWeather() } }.disabled(model.weatherBusy || !model.settings.weather.isValid)
                if model.weatherBusy || searching { ProgressView().controlSize(.small) }
                Text(model.weatherStatus).foregroundStyle(.secondary)
            }
        }.textFieldStyle(.roundedBorder)
    }
    private func search() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !searching, !text.isEmpty else { return }
        searching = true; searchStatus = ""
        Task { @MainActor in
            defer { searching = false }
            do {
                cities = try await WeatherClient.cities(query: text)
                if cities.isEmpty { searchStatus = "没有找到城市，可尝试英文或拼音名称" }
            } catch { searchStatus = "搜索失败，请检查网络后重试" }
        }
    }
}
