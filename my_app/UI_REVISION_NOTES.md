# EduCompass UI Revision

This revision changes presentation only. Application architecture, navigation, providers, API calls, Firebase, JWT, recommendation, enrollment, SSLCOMMERZ, deep-link and database logic were not changed.

## Requested refinements

- Login and registration forms are centered vertically and horizontally.
- Equal top and bottom spacing is preserved by the centered layout.
- The authentication body no longer uses a scroll view.
- On short screens or while the keyboard is open, the auth card scales down instead of producing a RenderFlex overflow.
- Shared spacing, card radii, app bars, buttons, inputs and bottom navigation are slightly more compact.
- Course list thumbnails were reduced slightly for cleaner density.
- Course thumbnails and hero images use `BoxFit.cover`, center alignment, high filter quality and existing fallbacks.
- The course skills section remains a bounded internal scroll box for courses with more than six skills; its height was reduced to 210 dp.
- Similar-course cards were resized to avoid vertical overflow.
- The sticky course action bar was reduced and retains SafeArea protection.
- Bottom navigation height was reduced while preserving the current routes and tab logic.

## Modified files

- `lib/theme.dart`
- `lib/widgets/design.dart`
- `lib/course_image.dart`
- `lib/screens/auth_chrome.dart`
- `lib/screens/login_screen.dart`
- `lib/screens/register_screen.dart`
- `lib/screens/shell_screen.dart`
- `lib/screens/home_screen.dart`
- `lib/screens/recommendations_screen.dart`
- `lib/screens/favorites_screen.dart`
- `lib/screens/my_courses_screen.dart`
- `lib/screens/course_details_screen.dart`

## Validation

- Structural bracket scan passed for all 35 Dart files.
- Flutter SDK was not available in this environment, so run `flutter analyze` and `flutter test` locally before release.
