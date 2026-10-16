import SwiftUI

struct AttendanceServicePicker: View {
    @ObservedObject var model: WorkBarModel
    var body: some View {
        Picker("연동 서비스", selection: Binding(get: { model.selectedService }, set: { service in
            Task { await model.selectService(service) }
        })) {
            ForEach(AttendanceService.allCases, id: \.self) { service in
                Text(service.name).tag(service)
            }
        }
        .pickerStyle(.segmented)
        .disabled(model.isSigningOut)
        .accessibilityLabel("연동 서비스")
    }
}
