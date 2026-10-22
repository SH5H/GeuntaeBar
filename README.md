# Geuntae bar

원티드스페이스·flex 근무시간을 macOS 메뉴 막대에 보여주는 앱입니다.

월간 요약의 **남은 근무일**과 **하루 필요**는 오늘을 제외한 근무일 기준입니다.
오늘까지 반영된 실적을 뺀 남은 필수시간을 나누어 소수점 한 자리로 표시합니다(6시간 50분 → 6.8시간).
남은 근무일이 없으면 하루 필요는 `—`로 표시하며, 오늘의 최소 근무 목표는 별도로 유지합니다.

<p>
  <img src="docs/images/menu.png" width="340" alt="오늘 진행률과 이번 달 누적 근무 패널">
  <img src="docs/images/options.png" width="440" alt="연동 서비스, 출근 확인 알림, 사용자 지정 휴일 옵션">
</p>

## 설치 방법

```sh
git clone https://github.com/SH5H/GeuntaeBar.git
cd GeuntaeBar
./install.sh
```

## flex 재연결

저장된 세션의 자동 갱신이 인증 오류(`400 / AUTH_400_000`)로 거절되면 **flex 재연결이 필요합니다**로 안내합니다.
설정에서 **flex 다시 로그인**으로 연결을 복구할 수 있습니다. 일반 조회 오류나 서버 장애는 기존 로그인을 유지합니다.
