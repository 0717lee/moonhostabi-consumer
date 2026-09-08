#ifndef _WIN32
#define _GNU_SOURCE
#endif

#include <errno.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#ifdef _WIN32
#include <windows.h>
#else
#include <dirent.h>
#include <fcntl.h>
#include <sys/stat.h>
#include <unistd.h>
#if defined(__linux__)
#include <sys/syscall.h>
#ifndef RENAME_NOREPLACE
#define RENAME_NOREPLACE (1 << 0)
#endif
#endif
#endif

#include "moonbit.h"

#ifdef __cplusplus
extern "C" {
#endif

MOONBIT_FFI_EXPORT int moonhostabi_write_stderr(
    moonbit_bytes_t bytes,
    int length) {
  size_t written = fwrite(bytes, 1, (size_t)length, stderr);
  int flushed = fflush(stderr);
  return written == (size_t)length && flushed == 0 ? 0 : -1;
}

#ifdef _WIN32
typedef moonbit_string_t moonhostabi_path_t;
#else
typedef moonbit_bytes_t moonhostabi_path_t;
#endif

#ifdef _WIN32
static const wchar_t *moonhostabi_owned_names[] = {
    L"adapter.ts",
    L"moonhostabi.contract.json",
    L"moonhostabi.manifest.json"};

static int moonhostabi_owned_name_index(const wchar_t *name) {
  for (int index = 0; index < 3; index++) {
    if (wcscmp(name, moonhostabi_owned_names[index]) == 0) {
      return index;
    }
  }
  return -1;
}

static wchar_t *moonhostabi_join_windows_path(
    const wchar_t *directory,
    const wchar_t *name) {
  size_t directory_length = wcslen(directory);
  size_t name_length = wcslen(name);
  int needs_separator = directory_length > 0 &&
      directory[directory_length - 1] != L'\\' &&
      directory[directory_length - 1] != L'/';
  size_t length = directory_length + (size_t)needs_separator + name_length + 1;
  wchar_t *result = (wchar_t *)malloc(length * sizeof(wchar_t));
  if (result == NULL) {
    return NULL;
  }
  wmemcpy(result, directory, directory_length);
  size_t position = directory_length;
  if (needs_separator) {
    result[position++] = L'\\';
  }
  wmemcpy(result + position, name, name_length);
  result[position + name_length] = L'\0';
  return result;
}

static int moonhostabi_cleanup_generation_directory_windows(
    const wchar_t *directory) {
  /* Omitting FILE_SHARE_DELETE pins the root path while path-based Win32
     enumeration and deletion run. OPEN_REPARSE_POINT keeps links opaque. */
  HANDLE directory_handle = CreateFileW(
      directory,
      FILE_LIST_DIRECTORY | FILE_READ_ATTRIBUTES,
      FILE_SHARE_READ | FILE_SHARE_WRITE,
      NULL,
      OPEN_EXISTING,
      FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
      NULL);
  if (directory_handle == INVALID_HANDLE_VALUE) {
    return -1;
  }
  BY_HANDLE_FILE_INFORMATION directory_information;
  if (!GetFileInformationByHandle(directory_handle, &directory_information)) {
    CloseHandle(directory_handle);
    return -1;
  }
  if ((directory_information.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) == 0 ||
      (directory_information.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
    CloseHandle(directory_handle);
    return 1;
  }

  int seen[3] = {0, 0, 0};
  int scan_result = 0;
  wchar_t *pattern = moonhostabi_join_windows_path(directory, L"*");
  if (pattern == NULL) {
    CloseHandle(directory_handle);
    return -1;
  }
  WIN32_FIND_DATAW entry;
  HANDLE search = FindFirstFileW(pattern, &entry);
  free(pattern);
  if (search == INVALID_HANDLE_VALUE) {
    if (GetLastError() != ERROR_FILE_NOT_FOUND) {
      CloseHandle(directory_handle);
      return -1;
    }
  } else {
    do {
      if (wcscmp(entry.cFileName, L".") == 0 ||
          wcscmp(entry.cFileName, L"..") == 0) {
        continue;
      }
      int index = moonhostabi_owned_name_index(entry.cFileName);
      if (index < 0 ||
          (entry.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY) != 0 ||
          (entry.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
        scan_result = 1;
        break;
      }
      seen[index] = 1;
    } while (FindNextFileW(search, &entry));
    DWORD scan_error = GetLastError();
    if (!FindClose(search) && scan_result == 0) {
      scan_result = -1;
    }
    if (scan_result == 0 && scan_error != ERROR_NO_MORE_FILES) {
      scan_result = -1;
    }
  }
  if (scan_result != 0) {
    CloseHandle(directory_handle);
    return scan_result;
  }

  /* The complete directory is validated before the first destructive call. */
  for (int index = 0; index < 3; index++) {
    if (!seen[index]) {
      continue;
    }
    wchar_t *child = moonhostabi_join_windows_path(
        directory,
        moonhostabi_owned_names[index]);
    if (child == NULL) {
      CloseHandle(directory_handle);
      return -1;
    }
    DWORD attributes = GetFileAttributesW(child);
    if (attributes == INVALID_FILE_ATTRIBUTES ||
        (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0 ||
        (attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
      free(child);
      CloseHandle(directory_handle);
      return 1;
    }
    if (!DeleteFileW(child)) {
      free(child);
      CloseHandle(directory_handle);
      return -1;
    }
    free(child);
  }
  CloseHandle(directory_handle);
  return RemoveDirectoryW(directory) ? 0 : -1;
}
#else
static const char *moonhostabi_owned_names[] = {
    "adapter.ts",
    "moonhostabi.contract.json",
    "moonhostabi.manifest.json"};

static int moonhostabi_owned_name_index(const char *name) {
  for (int index = 0; index < 3; index++) {
    if (strcmp(name, moonhostabi_owned_names[index]) == 0) {
      return index;
    }
  }
  return -1;
}

static int moonhostabi_cleanup_generation_directory_unix(
    const char *directory) {
  /* The directory fd pins the verified inode; every child operation remains
     relative to it, so replacing the path with a symlink cannot redirect us. */
  int open_flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW;
#ifdef O_CLOEXEC
  open_flags |= O_CLOEXEC;
#endif
  int directory_fd = open(directory, open_flags);
  if (directory_fd < 0) {
    return errno == ELOOP || errno == ENOTDIR || errno == ENOENT ? 1 : -1;
  }
  struct stat directory_status;
  if (fstat(directory_fd, &directory_status) != 0 ||
      !S_ISDIR(directory_status.st_mode)) {
    close(directory_fd);
    return 1;
  }

  int stream_fd = dup(directory_fd);
  if (stream_fd < 0) {
    close(directory_fd);
    return -1;
  }
  DIR *stream = fdopendir(stream_fd);
  if (stream == NULL) {
    close(stream_fd);
    close(directory_fd);
    return -1;
  }
  int seen[3] = {0, 0, 0};
  struct stat seen_status[3];
  int scan_result = 0;
  errno = 0;
  struct dirent *entry;
  while ((entry = readdir(stream)) != NULL) {
    if (strcmp(entry->d_name, ".") == 0 ||
        strcmp(entry->d_name, "..") == 0) {
      continue;
    }
    int index = moonhostabi_owned_name_index(entry->d_name);
    if (index < 0) {
      scan_result = 1;
      break;
    }
    if (fstatat(
            directory_fd,
            entry->d_name,
            &seen_status[index],
            AT_SYMLINK_NOFOLLOW) != 0) {
      scan_result = -1;
      break;
    }
    if (!S_ISREG(seen_status[index].st_mode)) {
      scan_result = 1;
      break;
    }
    seen[index] = 1;
  }
  if (scan_result == 0 && errno != 0) {
    scan_result = -1;
  }
  if (closedir(stream) != 0 && scan_result == 0) {
    scan_result = -1;
  }
  if (scan_result != 0) {
    close(directory_fd);
    return scan_result;
  }

  for (int index = 0; index < 3; index++) {
    if (!seen[index]) {
      continue;
    }
    struct stat current_status;
    if (fstatat(
            directory_fd,
            moonhostabi_owned_names[index],
            &current_status,
            AT_SYMLINK_NOFOLLOW) != 0 ||
        !S_ISREG(current_status.st_mode) ||
        current_status.st_dev != seen_status[index].st_dev ||
        current_status.st_ino != seen_status[index].st_ino) {
      close(directory_fd);
      return 1;
    }
    if (unlinkat(directory_fd, moonhostabi_owned_names[index], 0) != 0) {
      close(directory_fd);
      return -1;
    }
  }

  struct stat current_directory_status;
  if (lstat(directory, &current_directory_status) != 0 ||
      current_directory_status.st_dev != directory_status.st_dev ||
      current_directory_status.st_ino != directory_status.st_ino) {
    close(directory_fd);
    return 1;
  }
  close(directory_fd);
  return rmdir(directory) == 0 ? 0 : -1;
}
#endif

MOONBIT_FFI_EXPORT int moonhostabi_directory_kind(moonhostabi_path_t path) {
#ifdef _WIN32
  DWORD attributes = GetFileAttributesW((const wchar_t *)path);
  if (attributes == INVALID_FILE_ATTRIBUTES) {
    HANDLE handle = CreateFileW(
        (const wchar_t *)path,
        FILE_READ_ATTRIBUTES,
        FILE_SHARE_READ | FILE_SHARE_WRITE | FILE_SHARE_DELETE,
        NULL,
        OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT,
        NULL);
    if (handle == INVALID_HANDLE_VALUE) {
      DWORD error = GetLastError();
      return error == ERROR_FILE_NOT_FOUND || error == ERROR_PATH_NOT_FOUND ? 1 : -1;
    }
    BY_HANDLE_FILE_INFORMATION information;
    if (!GetFileInformationByHandle(handle, &information)) {
      CloseHandle(handle);
      return -1;
    }
    CloseHandle(handle);
    attributes = information.dwFileAttributes;
  }
  if ((attributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0) {
    return 3;
  }
  return (attributes & FILE_ATTRIBUTE_DIRECTORY) != 0 ? 0 : 2;
#else
  struct stat status;
  if (lstat((const char *)path, &status) != 0) {
    return errno == ENOENT || errno == ENOTDIR ? 1 : -1;
  }
  if (S_ISLNK(status.st_mode)) {
    return 3;
  }
  return S_ISDIR(status.st_mode) ? 0 : 2;
#endif
}

MOONBIT_FFI_EXPORT int moonhostabi_cleanup_generation_directory(
    moonhostabi_path_t directory) {
#ifdef _WIN32
  return moonhostabi_cleanup_generation_directory_windows(
      (const wchar_t *)directory);
#else
  return moonhostabi_cleanup_generation_directory_unix(
      (const char *)directory);
#endif
}

MOONBIT_FFI_EXPORT int moonhostabi_write_new_file(
    moonhostabi_path_t path,
    moonbit_bytes_t bytes,
    int length) {
#ifdef _WIN32
  FILE *file = _wfopen((const wchar_t *)path, L"wbx");
#else
  FILE *file = fopen((const char *)path, "wbx");
#endif
  if (file == NULL) {
    return errno == EEXIST ? 1 : -1;
  }
  size_t written = fwrite(bytes, 1, (size_t)length, file);
  int flushed = fflush(file);
  int closed = fclose(file);
  if (written == (size_t)length && flushed == 0 && closed == 0) {
    return 0;
  }
#ifdef _WIN32
  _wremove((const wchar_t *)path);
#else
  remove((const char *)path);
#endif
  return -1;
}

MOONBIT_FFI_EXPORT int moonhostabi_rename_directory_noreplace(
    moonhostabi_path_t source,
    moonhostabi_path_t destination) {
#ifdef _WIN32
  if (MoveFileExW(
          (const wchar_t *)source,
          (const wchar_t *)destination,
          MOVEFILE_WRITE_THROUGH)) {
    return 0;
  }
  DWORD error = GetLastError();
  return error == ERROR_ALREADY_EXISTS || error == ERROR_FILE_EXISTS ? 1 : -1;
#elif defined(__linux__) && defined(SYS_renameat2)
  int result = (int)syscall(
      SYS_renameat2,
      AT_FDCWD,
      (const char *)source,
      AT_FDCWD,
      (const char *)destination,
      RENAME_NOREPLACE);
  if (result == 0) {
    return 0;
  }
  return errno == EEXIST || errno == ENOTEMPTY ? 1 : -1;
#else
  (void)source;
  (void)destination;
  errno = ENOTSUP;
  return -1;
#endif
}

#ifdef __cplusplus
}
#endif
