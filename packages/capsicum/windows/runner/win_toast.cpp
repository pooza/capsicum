#include "win_toast.h"

#include <windows.h>

#include <winrt/Windows.Data.Xml.Dom.h>
#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.UI.Notifications.h>

#include <string>

namespace {

std::wstring Utf8ToWide(const std::string& s) {
  if (s.empty()) {
    return std::wstring();
  }
  int len = MultiByteToWideChar(CP_UTF8, 0, s.data(),
                                static_cast<int>(s.size()), nullptr, 0);
  if (len <= 0) {
    return std::wstring();
  }
  std::wstring wide(static_cast<size_t>(len), L'\0');
  MultiByteToWideChar(CP_UTF8, 0, s.data(), static_cast<int>(s.size()),
                      wide.data(), len);
  return wide;
}

std::wstring XmlEscape(const std::wstring& s) {
  std::wstring out;
  out.reserve(s.size());
  for (wchar_t c : s) {
    switch (c) {
      case L'&': out += L"&amp;"; break;
      case L'<': out += L"&lt;"; break;
      case L'>': out += L"&gt;"; break;
      case L'"': out += L"&quot;"; break;
      case L'\'': out += L"&apos;"; break;
      default: out.push_back(c); break;
    }
  }
  return out;
}

}  // namespace

namespace capsicum {

bool ShowRawToast(const std::string& title, const std::string& body,
                  const std::string& launch_arg, const std::string& tag) {
  try {
    using winrt::Windows::Data::Xml::Dom::XmlDocument;
    using winrt::Windows::UI::Notifications::ToastNotification;
    using winrt::Windows::UI::Notifications::ToastNotificationManager;

    const std::wstring w_title = XmlEscape(Utf8ToWide(title));
    const std::wstring w_body = XmlEscape(Utf8ToWide(body));
    const std::wstring w_launch = XmlEscape(Utf8ToWide(launch_arg));

    // ToastGeneric テンプレート（title + body の 2 行）。タップ時は launch を
    // アクティベータ（capsicum の toast_activator COM サーバ）へ渡し、Dart 側で
    // 遷移を処理する。
    std::wstring xml = L"<toast";
    if (!w_launch.empty()) {
      xml += L" launch=\"" + w_launch + L"\" activationType=\"foreground\"";
    }
    xml += L"><visual><binding template=\"ToastGeneric\">";
    xml += L"<text>" + w_title + L"</text>";
    xml += L"<text>" + w_body + L"</text>";
    xml += L"</binding></visual></toast>";

    XmlDocument doc;
    doc.LoadXml(winrt::hstring(xml));
    ToastNotification toast{doc};

    if (!tag.empty()) {
      std::wstring w_tag = Utf8ToWide(tag);
      // WNS の通知 tag は最大 64 文字。SNS の通知 ID をそのまま使うと超える
      // ことがあるので切り詰める（dedup / 差し替えの近似で十分）。
      if (w_tag.size() > 64) {
        w_tag.resize(64);
      }
      toast.Tag(winrt::hstring(w_tag));
    }

    // パッケージ ID を持つ起動（MSIX）では既定 AUMID で通知できる。
    ToastNotificationManager::CreateToastNotifier().Show(toast);
    return true;
  } catch (...) {
    // 非 MSIX 起動（パッケージ ID 無し）・WinRT 例外・XML 不正時は false。
    return false;
  }
}

}  // namespace capsicum
