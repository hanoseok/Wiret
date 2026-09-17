import Foundation

/// 메뉴에 캘린더를 보여주기 위한 최소 정보. EventKit 타입을 UI와 테스트에서 떼어낸다.
struct CalendarInfo: Equatable {
    let id: String
    let title: String
    /// 계정 이름(예: Google 계정 주소). 같은 이름의 캘린더를 구분하는 데 쓴다.
    let sourceTitle: String
}

/// 어떤 캘린더를 볼지 정하는 규칙.
///
/// 사용자가 고르지 않았으면 예전처럼 Google 캘린더를 쓰고, Google이 없으면 전체를 본다.
/// 골라 둔 캘린더가 계정 삭제 등으로 모두 사라졌을 때도 같은 자동 규칙으로 되돌아간다.
/// 아무것도 못 보는 상태로 조용히 빠지면 자동 녹음이 멈춘 이유를 알 수 없기 때문이다.
enum CalendarSelection {
    static func resolve(
        all: [CalendarInfo],
        googleIDs: Set<String>,
        selected: Set<String>
    ) -> [CalendarInfo] {
        let chosen = all.filter { selected.contains($0.id) }
        if !chosen.isEmpty {
            return chosen
        }

        let google = all.filter { googleIDs.contains($0.id) }
        return google.isEmpty ? all : google
    }

    /// 사용자가 직접 고른 상태인지. 메뉴에서 "자동" 체크 표시를 정하는 데 쓴다.
    static func isAutomatic(all: [CalendarInfo], selected: Set<String>) -> Bool {
        !all.contains { selected.contains($0.id) }
    }
}
