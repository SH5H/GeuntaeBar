import SwiftUI

struct OnboardingWindow: View {
    @ObservedObject var model: WorkBarModel
    @ObservedObject var onboarding: OnboardingState
    @Environment(\.dismissWindow) private var dismissWindow
    @State private var loginAttempt = 0
    @State private var loginPageState = LoginWebView.LoadState.loading

    private let titles = ["근태 확인, 메뉴 막대에서", "원티드스페이스에 로그인", "이번 달 근무 흐름을 한눈에", "추가 수당 시작 기준선", "달력에서 휴가 설정", "출근 기록을 잊지 않도록"]
    private let descriptions = [
        "화면 위쪽의 아이콘을 좌클릭하거나 우클릭하면 근무시간을 볼 수 있어요. 패널 상단의 톱니바퀴를 누르면 옵션 창이 열려요.",
        "아래에서 평소 사용하던 계정으로 로그인해주세요. 로그인은 나중에 하고 기능부터 둘러볼 수도 있어요.",
        "월간 막대는 최대 근무 가능 시간까지 펼쳐져요. 세 가지 색의 선과 아래 설명으로 각 기준을 확인해요.",
        "월간 막대의 보라색 선은 필수시간을 채운 뒤 리프레시 데이를 반영한 수당 기준이에요. 실제 수당은 신청·승인과 급여 정산에 따라 달라져요.",
        "달력에서 날짜를 누른 뒤 유급·무급 휴가를 선택하세요. 두 휴가 모두 근무일과 필수·최대시간에서 빠지고, 유급 휴가만 수당 기준도 낮춰요. 회사 시스템에 휴가를 신청하지는 않아요.",
        "출근 기록이 없으면 알려드려요. 패널 상단의 톱니바퀴로 옵션 창을 열어 알림을 켜고 끄거나 기준과 지연 시간을 바꿀 수 있어요."
    ]
    private let symbols = ["menubar.rectangle", "person.crop.circle", "chart.bar.xaxis", "calendar.badge.clock", "calendar.badge.minus", "bell.badge"]
    private let accent = Color(red: 0.16, green: 0.66, blue: 0.73)
    private var isSignedIn: Bool { model.loginCompleted }

    var body: some View {
        VStack(spacing: 20) {
            HStack {
                Label("Geuntae bar", systemImage: "clock")
                    .font(.headline)
                Spacer()
                Text("\(onboarding.step + 1) / \(onboarding.stepCount)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("총 \(onboarding.stepCount)단계 중 \(onboarding.step + 1)단계")
            }
            Divider()
            GeometryReader { geometry in
                ScrollView {
                    VStack(alignment: .leading, spacing: 22) {
                        introduction
                        if onboarding.isSignInStep {
                            signIn
                                .frame(height: max(340, geometry.size.height - 155))
                        } else {
                            VStack(alignment: .leading, spacing: 14) {
                                illustration
                            }
                            .padding(20)
                            .frame(maxWidth: .infinity, minHeight: 160, alignment: .leading)
                            .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
                        }
                        Text(onboarding.isSignInStep
                             ? "로그인 세션은 macOS 키체인에 저장해요. 비밀번호는 저장하지 않아요."
                             : onboarding.isLastStep && !isSignedIn
                             ? "로그인은 나중에 패널 상단의 톱니바퀴를 눌러 옵션 창의 ‘로그인’에서 할 수 있어요."
                             : "언제든 옵션 창의 ‘사용 가이드’에서 다시 볼 수 있어요.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .frame(maxWidth: onboarding.isSignInStep ? .infinity : 520)
                    .frame(maxWidth: .infinity, minHeight: geometry.size.height,
                           alignment: onboarding.isSignInStep ? .top : .center)
                }
                .id(onboarding.step)
            }
            Divider()
            HStack(spacing: 12) {
                if onboarding.isSignInStep && !isSignedIn {
                    Button("나중에 로그인", action: onboarding.skipSignIn)
                        .buttonStyle(.borderless)
                        .help("로그인하지 않고 기능 안내를 둘러봅니다.")
                } else {
                    Button("닫기") {
                        onboarding.close()
                        dismissWindow(id: "onboarding")
                    }
                    .buttonStyle(.borderless)
                }
                Spacer()
                Button("이전", action: onboarding.previous)
                    .disabled(onboarding.step == 0)
                Button(onboarding.isLastStep ? "시작하기" : onboarding.isSignInStep ? "안내 계속" : "다음") {
                    if onboarding.isLastStep { finish() }
                    else { onboarding.next(isSignedIn: isSignedIn) }
                }
                .buttonStyle(.borderedProminent)
                .tint(accent)
                .disabled(onboarding.isSignInStep && !isSignedIn)
                .keyboardShortcut(onboarding.isSignInStep && !isSignedIn ? nil : .defaultAction)
            }
        }
        .padding(28)
        .frame(minWidth: 600, minHeight: 360)
        .onDisappear { onboarding.close() }
    }

    private var introduction: some View {
        VStack(alignment: .leading, spacing: 12) {
            if !onboarding.isSignInStep {
                Image(systemName: symbols[onboarding.step])
                    .font(.system(size: 32))
                    .foregroundStyle(accent)
                    .accessibilityHidden(true)
            }
            Text(onboarding.isSignInStep ? "근태 서비스 연결" : titles[onboarding.step])
                .font(.title2.bold())
                .accessibilityAddTraits(.isHeader)
            Text(onboarding.isSignInStep && isSignedIn
                 ? "근태 정보를 연결했어요. 준비되면 기능 안내를 계속하세요."
                 : onboarding.isSignInStep && model.selectedService == .flex
                 ? "flex 계정으로 로그인하면 근무 기준과 기록을 자동으로 가져와요."
                 : descriptions[onboarding.step])
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var signIn: some View {
        VStack(spacing: 12) {
            AttendanceServicePicker(model: model)
            if isSignedIn {
                VStack(spacing: 16) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(accent)
                        .accessibilityHidden(true)
                    Text("연결 완료").font(.title3.bold())
                    Text("아래 ‘안내 계속’을 눌러 주요 기능을 살펴보세요.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(accent.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
            } else {
                VStack(spacing: 0) {
                    LoginWebView(model: model, loadState: $loginPageState)
                        .id("\(model.selectedService.rawValue)-\(loginAttempt)")
                        .id(ObjectIdentifier(model.loginWebDataStore))
                    Divider()
                    HStack(spacing: 8) {
                        if model.isRefreshing || loginPageState == .loading {
                            ProgressView().controlSize(.small)
                        }
                        Text(loginStatus)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                        Spacer()
                        Button("다시 시도") {
                            model.beginSignIn()
                            loginPageState = .loading
                            loginAttempt += 1
                        }
                        .disabled(model.isRefreshing)
                    }
                    .padding(10)
                }
                .background(.background, in: RoundedRectangle(cornerRadius: 14))
                .clipShape(RoundedRectangle(cornerRadius: 14))
                .overlay(RoundedRectangle(cornerRadius: 14).stroke(.quaternary))
            }
        }
    }

    private var loginStatus: String {
        if model.isRefreshing { return "근태 정보를 확인하고 연결하는 중…" }
        switch loginPageState {
        case .loading: return "로그인 화면을 불러오는 중…"
        case .failed(let message): return message
        case .ready:
            return model.loginFailureMessage ?? "\(model.selectedService.name) 계정으로 로그인해주세요."
        }
    }

    @ViewBuilder
    private var illustration: some View {
        switch onboarding.step {
        case 0:
            HStack {
                Text("화면 위쪽 메뉴 막대")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Label("근무 4시간 0분", systemImage: "clock")
                    .font(.callout.weight(.semibold))
                    .padding(8)
                    .background(accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 8))
            }
            Divider()
            Label("근태 정보는 5분마다 자동으로 갱신해요.", systemImage: "arrow.clockwise")
            Label("출퇴근 기록은 이용하는 근태 서비스에서 입력해요.", systemImage: "arrow.up.right.square")
            Text("위 근무시간은 안내용 예시예요.").font(.caption).foregroundStyle(.secondary)
        case 2:
            HStack {
                Text("이번 달 · 예시").fontWeight(.semibold)
                Spacer()
                Text("누적 96시간 · 최대 200시간").foregroundStyle(.secondary)
            }
            let markers: [(position: Double?, color: Color, description: String)] = [
                (0.56, .red, "최소 목표 112시간"),
                (0.8, .blue, "필수 160시간"),
                (0.84, .purple, "수당 기준 168시간")
            ]
            WorkProgressBar(fill: 0.48, markers: markers, value: "누적 96시간", label: "월간 근무 예시")
            ForEach(markers.indices, id: \.self) { index in
                HStack(spacing: 6) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 8))
                        .foregroundStyle(markers[index].color)
                        .accessibilityHidden(true)
                    Text(markers[index].description)
                }
                .font(.caption)
            }
            Text("누적, 남은 근무일과 최대 근무 가능 시간도 월간 막대 주변에서 확인해요.")
                .font(.callout)
        case 3:
            Text("추가 수당 시작 기준").fontWeight(.semibold)
            Text("개인 필수 근무시간\n+ 리프레시 데이 수 × 하루 기준시간")
                .font(.callout)
                .lineSpacing(5)
            Divider()
            Text("실제 수당은 근태 신청·승인 및 급여 정산에 따라 달라져요.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case 4:
            Label("달력에서 날짜 선택", systemImage: "calendar")
            Label("휴가 없음 · 유급 휴가 · 무급 휴가", systemImage: "checkmark.circle")
            Divider()
            Text("선택은 이 Mac에 저장되며 근태 서비스·계정별로 구분해요. ‘휴가 없음’을 선택하면 앱에서 지정한 휴가만 해제돼요.")
                .font(.callout)
        default:
            Label("근무표 시작 또는 최근 출근 평균을 기준으로", systemImage: "clock")
            Label("기준 시각에서 0~240분 뒤에 알림", systemImage: "timer")
            Divider()
            Text("알림을 켜면 Mac 로그인 시 자동 실행도 등록해요. macOS에서 알림 또는 로그인 항목 승인을 요청하면 허용해주세요.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func finish() {
        onboarding.finish()
        dismissWindow(id: "onboarding")
    }
}
