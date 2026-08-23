#include "local_state_files.h"

#include <winrt/Windows.Foundation.h>
#include <winrt/Windows.Storage.h>

#include <fstream>

namespace capsicum {

std::wstring LocalStateFilePath(const wchar_t* name) {
  try {
    winrt::hstring folder =
        winrt::Windows::Storage::ApplicationData::Current().LocalFolder().Path();
    return std::wstring(folder.c_str(), folder.size()) + L"\\" + name;
  } catch (...) {
    // 非パッケージ起動（`flutter run -d windows`）では LocalFolder を引けない。
    // 空文字列は「この経路は使えない」の意で、読み書き側が素通りする。
    return std::wstring();
  }
}

std::string ReadFileUtf8(const std::wstring& path) {
  if (path.empty()) return std::string();
  std::ifstream f(path, std::ios::binary | std::ios::ate);
  if (!f) {
    return std::string();
  }
  std::streamoff size = f.tellg();
  if (size <= 0) {
    return std::string();
  }
  std::string out(static_cast<size_t>(size), '\0');
  f.seekg(0);
  f.read(out.data(), static_cast<std::streamsize>(size));
  return out;
}

std::string ReadLocalStateFileUtf8(const wchar_t* name) {
  return ReadFileUtf8(LocalStateFilePath(name));
}

}  // namespace capsicum
