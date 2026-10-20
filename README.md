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
