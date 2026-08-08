/* BCrypt algorithm pseudo-handles (available since Windows 10 1703), missing
 * from mingw-w64 headers before v11. Needed by the bundled google-cloud-cpp
 * (google/cloud/internal/win32/ and google/cloud/storage/internal/). This
 * file is force-included in every TU via CXXFLAGS, so it deliberately
 * includes nothing itself; BCRYPT_ALG_HANDLE is resolved at the point of
 * use. Values match mingw-w64 master include/bcrypt.h. */
#ifndef BCRYPT_MD5_ALG_HANDLE
#define BCRYPT_MD5_ALG_HANDLE ((BCRYPT_ALG_HANDLE) 0x00000021)
#endif
#ifndef BCRYPT_SHA256_ALG_HANDLE
#define BCRYPT_SHA256_ALG_HANDLE ((BCRYPT_ALG_HANDLE) 0x00000041)
#endif
#ifndef BCRYPT_HMAC_SHA256_ALG_HANDLE
#define BCRYPT_HMAC_SHA256_ALG_HANDLE ((BCRYPT_ALG_HANDLE) 0x000000b1)
#endif
#ifndef BCRYPT_RSA_ALG_HANDLE
#define BCRYPT_RSA_ALG_HANDLE ((BCRYPT_ALG_HANDLE) 0x000000e1)
#endif
