cmake_minimum_required(VERSION 3.14)
project(runner LANGUAGES CXX)

# Define the application target. To change its name, change BINARY_NAME in the
# top-level CMakeLists.txt, not the value here, or `flutter run` will no longer
# work.
#
# Any new source files that you add to the application should be added here.
add_executable(${BINARY_NAME} WIN32
  "flutter_window.cpp"
  "main.cpp"
  "smtc_now_playing.cpp"
  "wns_push.cpp"
  "notification_type_label.cpp"
  "push_diagnostics.cpp"
  "web_push_decrypt.cpp"
  "web_push_key_reader.cpp"
  "web_push_payload.cpp"
  "web_push_receive.cpp"
  "win_toast.cpp"
  "utils.cpp"
  "win32_window.cpp"
  "${FLUTTER_MANAGED_DIR}/generated_plugin_registrant.cc"
  "Runner.rc"
  "runner.exe.manifest"
)

# *_test.cpp は runner ターゲットに含めない（独自 main を持つスタンドアロン
# 単体テスト）。VS Developer 環境で直接ビルド・実行する（フルビルド不要）:
#   cl /EHsc /std:c++17 web_push_decrypt_test.cpp web_push_decrypt.cpp ^
#      /link bcrypt.lib
#   cl /EHsc /std:c++17 web_push_key_reader_test.cpp web_push_key_reader.cpp ^
#      /link crypt32.lib shell32.lib ole32.lib version.lib
#   cl /EHsc /std:c++17 web_push_payload_test.cpp web_push_payload.cpp
#   cl /EHsc /std:c++17 web_push_receive_test.cpp web_push_receive.cpp ^
#      web_push_key_reader.cpp web_push_decrypt.cpp web_push_payload.cpp ^
#      notification_type_label.cpp ^
#      /link crypt32.lib bcrypt.lib shell32.lib ole32.lib version.lib

# Apply the standard set of build settings. This can be removed for applications
# that need different build settings.
apply_standard_settings(${BINARY_NAME})

# Add preprocessor definitions for the build version.
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION=\"${FLUTTER_VERSION}\"")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MAJOR=${FLUTTER_VERSION_MAJOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_MINOR=${FLUTTER_VERSION_MINOR}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_PATCH=${FLUTTER_VERSION_PATCH}")
target_compile_definitions(${BINARY_NAME} PRIVATE "FLUTTER_VERSION_BUILD=${FLUTTER_VERSION_BUILD}")

# Disable Windows macros that collide with C++ standard library functions.
target_compile_definitions(${BINARY_NAME} PRIVATE "NOMINMAX")

# Add dependency libraries and include directories. Add any application-specific
# dependencies here.
target_link_libraries(${BINARY_NAME} PRIVATE flutter flutter_wrapper_app)
target_link_libraries(${BINARY_NAME} PRIVATE "dwmapi.lib")
# C++/WinRT（System Media Transport Controls の取得, #466 / #484）。
target_link_libraries(${BINARY_NAME} PRIVATE "windowsapp.lib")
# CNG (Cryptography API: Next Generation)。Web Push (RFC 8291) の ECDH P-256 /
# HKDF-SHA256 / AES-128-GCM 復号で使う (#474 フェーズ2 web_push_decrypt.cpp)。
target_link_libraries(${BINARY_NAME} PRIVATE "bcrypt.lib")
# DPAPI (CryptUnprotectData) + APPDATA 解決 (SHGetKnownFolderPath /
# VerQueryValue)。flutter_secure_storage.dat から push 鍵を読む
# (#474 フェーズ2 web_push_key_reader.cpp)。
target_link_libraries(${BINARY_NAME} PRIVATE "crypt32.lib" "shell32.lib" "ole32.lib" "version.lib")
target_include_directories(${BINARY_NAME} PRIVATE "${CMAKE_SOURCE_DIR}")

# WNS push バックグラウンドタスク DLL (#474 フェーズ C)。
# アプリ完全終了中の WNS raw 通知を受ける WinRT in-process server で、
# backgroundTaskHost.exe にロードされる。復号・鍵読み・表示の各部品
# (web_push_* / win_toast) を runner と共有してビルドする（Flutter 非依存）。
add_library(capsicum_push_task SHARED
  "push_background_task.cpp"
  "push_background_task.def"
  "notification_type_label.cpp"
  "push_diagnostics.cpp"
  "web_push_decrypt.cpp"
  "web_push_key_reader.cpp"
  "web_push_payload.cpp"
  "web_push_receive.cpp"
  "win_toast.cpp"
)
apply_standard_settings(capsicum_push_task)
target_compile_definitions(capsicum_push_task PRIVATE "NOMINMAX")
target_link_libraries(capsicum_push_task PRIVATE "windowsapp.lib" "bcrypt.lib")
target_link_libraries(capsicum_push_task PRIVATE "crypt32.lib" "shell32.lib" "ole32.lib" "version.lib")
target_include_directories(capsicum_push_task PRIVATE "${CMAKE_SOURCE_DIR}")
# 出力名はマニフェスト inProcessServer の Path と一致させる。
set_target_properties(capsicum_push_task PROPERTIES OUTPUT_NAME "push_background_task")
# capsicum.exe と同じ Release バンドルフォルダへ同梱する（MSIX が拾えるように）。
install(TARGETS capsicum_push_task RUNTIME DESTINATION "${CMAKE_INSTALL_PREFIX}"
  COMPONENT Runtime)

# Run the Flutter tool portions of the build. This must not be removed.
add_dependencies(${BINARY_NAME} flutter_assemble)
