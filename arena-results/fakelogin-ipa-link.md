# Fake-login patched IPA

- Output: `spoti.pw-0.50.0-fakelogin.ipa`
- Download: https://filebin.net/spoti-pw-fakelogin-37465199770/spoti.pw-0.50.0-fakelogin.ipa
- GitHub Actions artifact: `spoti-pw-0.50.0-fakelogin-ipa` on run 37465199770
- Size: 130741511 bytes
- SHA-256: `97013166753abd7afd81e6d972a0e21716f534917936c9249335957d23b1318f`

Account/auth patch applied to `Payload/Spotify.app/Frameworks/spotifyglass.dylib`:

- account-present check returns true
- account status text returns `Plus is on`
- account label falls back to `this account`
- `/api/app/me` refresh is no-op to prevent test sign-out
- scheduled account refresh is no-op
- auth verify response parser returns success
- auth verify callback ignores transport/server errors
