# Flutter Widget Tree Library

**Purpose:** An offline-first, practical index of Flutter’s most useful built-in widgets and framework building blocks. It is organized by job-to-be-done, not alphabetical order.

> **Scope note:** Flutter evolves continually, and its complete API includes many highly specialized classes, delegates, render objects, and platform bindings. This reference is deliberately a *project-building field guide*: it covers the core widgets, common variants, rules, and decision points you need most often. Keep Flutter’s installed SDK API documentation as the source of truth for version-specific constructors and newly added widgets.

## How to use this file

1. Find the job you need in the tree below.
2. Read the one-line purpose.
3. Check **Practical Parent/Child Rules** before combining widgets.
4. Prefer the simplest widget that satisfies the layout or interaction.

## Mini widget tree example

```dart
MaterialApp
└─ Scaffold
   ├─ AppBar(title: Text('Dashboard'))
   ├─ NavigationBar
   └─ SafeArea
      └─ ListView.builder
         └─ Card
            └─ ListTile
               ├─ leading: Icon(...)
               ├─ title: Text(...)
               └─ trailing: IconButton(...)
```

## Tree index

```text
Flutter UI
├─ 00 Architecture & identity
├─ 01 App roots & screen structure
├─ 02–04 Layout & positioning
├─ 05 Text, icons, images & assets
├─ 06 Styling, surfaces & effects
├─ 07 Buttons, gestures & interaction
├─ 08 Forms, selection & pickers
├─ 09 Lists, grids & scrolling
├─ 10 Slivers
├─ 11 Navigation, routes & overlays
├─ 12 Async & state-dependent UI
├─ 13 Animation & motion
├─ 14 Theme, responsive design & i18n
├─ 15 Accessibility, focus & keyboard
├─ 16 Cupertino
├─ 17 Platform & desktop
├─ 18 Loading & feedback
├─ 19 Parent/child rules
└─ 20 Fast selection guide
```


## 00 — How Flutter Fits Together

- **`Widget`** — Immutable description of part of the UI; Flutter rebuilds widgets to describe the current interface.
- **`StatelessWidget`** — Widget with no mutable state of its own; rebuilds from inputs.
- **`StatefulWidget`** — Widget whose associated State can change during its lifetime.
- **`State`** — Holds mutable UI state; call setState() to request a rebuild.
- **`BuildContext`** — Location in the widget tree used to read themes, navigation, inherited data, and layout information.
- **`Key / ValueKey / ObjectKey / GlobalKey`** — Preserve identity when widgets move, reorder, or need state/form access. Use GlobalKey sparingly.
- **`InheritedWidget`** — Efficiently exposes data to descendants; basis of Theme, MediaQuery, and many state-management tools.
- **`Builder`** — Creates a fresh BuildContext, often to access an ancestor inserted just above it.

## 01 — App Roots & Screen Structure

- **`runApp`** — Starts Flutter and attaches the root widget to the screen.
- **`MaterialApp`** — Material app shell: theme, routes, localization, navigator, and default behaviors.
- **`CupertinoApp`** — Apple-style app shell with Cupertino navigation and defaults.
- **`WidgetsApp`** — Lower-level app shell used when you do not want Material or Cupertino defaults.
- **`Scaffold`** — Standard Material page frame: app bar, body, drawer, FAB, bottom navigation, sheets, snack bars.
- **`SafeArea`** — Pads content away from notches, status bars, gesture areas, and system UI.
- **`AppBar`** — Top Material bar for title, navigation, actions, tabs, and search.
- **`SliverAppBar`** — Collapsing/pinned/floating app bar used inside CustomScrollView.
- **`NavigationBar`** — Material 3 bottom destination selector.
- **`NavigationRail`** — Side destination selector for wide/tablet/desktop layouts.
- **`BottomAppBar`** — Bottom surface often used with a FloatingActionButton notch.
- **`Drawer / NavigationDrawer`** — Side navigation panel; NavigationDrawer is the Material 3 version.
- **`FloatingActionButton`** — Prominent primary action button, usually attached to Scaffold.
- **`PersistentFooterButtons`** — Legacy Scaffold footer action row; prefer BottomAppBar or bottom sheets in new designs.

## 02 — Layout: Multi-child Parents

- **`Row`** — Places children horizontally; use mainAxisAlignment and crossAxisAlignment to position them.
- **`Column`** — Places children vertically; constrain or scroll it when its contents can exceed screen height.
- **`Flex`** — General Row/Column; choose Axis.horizontal or Axis.vertical.
- **`Wrap`** — Flows children onto new lines when there is not enough room; useful for chips and tags.
- **`Stack`** — Paints children on top of one another; use for overlays, badges, and layered UIs.
- **`IndexedStack`** — Shows one child while keeping the other children alive.
- **`Flow`** — Advanced, paint-time child positioning via FlowDelegate.
- **`Table`** — Grid-like rows and columns with table sizing rules.
- **`CustomMultiChildLayout`** — Advanced multi-child layout controlled by a delegate.
- **`LayoutBuilder`** — Builds based on the parent’s constraints; core tool for responsive layout.
- **`OrientationBuilder`** — Builds differently for portrait versus landscape orientation.
- **`MediaQuery`** — Reads screen size, padding, text scaling, platform brightness, and other device context.
- **`Placeholder`** — Draws a visual placeholder during layout prototyping.

## 03 — Layout: Single-child Positioning & Sizing

- **`Container`** — Convenience box for padding, margin, constraints, decoration, alignment, transform, and child.
- **`Padding`** — Adds empty space around one child.
- **`Align`** — Aligns a child inside itself; can optionally size itself to the child.
- **`Center`** — Shorthand for Align(alignment: Alignment.center).
- **`SizedBox`** — Gives a child fixed width/height or adds fixed blank space.
- **`ConstrainedBox`** — Adds minimum/maximum size constraints to a child.
- **`UnconstrainedBox`** — Removes selected parent constraints; use carefully because overflow is possible.
- **`LimitedBox`** — Applies maximum size only when incoming constraints are unbounded.
- **`FractionallySizedBox`** — Sizes child as a fraction of available space.
- **`AspectRatio`** — Sizes a child to a chosen width-to-height ratio.
- **`FittedBox`** — Scales and positions a child to fit within available bounds.
- **`Expanded`** — Row/Column/Flex child that must fill remaining main-axis space.
- **`Flexible`** — Row/Column/Flex child allowed to use flexible space without necessarily filling it.
- **`Spacer`** — Flexible empty space in a Row, Column, or Flex.
- **`Baseline`** — Aligns a child to a specific text baseline.
- **`IntrinsicWidth / IntrinsicHeight`** — Sizes based on child intrinsic dimensions; expensive—avoid in large lists.
- **`OverflowBox`** — Lets child exceed parent constraints intentionally.
- **`Offstage`** — Lays out but does not paint/hit-test a child; remove inactive widgets instead when possible.
- **`Visibility`** — Shows, hides, or preserves layout/state of a child with configurable behavior.
- **`IgnorePointer`** — Makes descendants ignore pointer events while still painting them.
- **`AbsorbPointer`** — Consumes pointer events so descendants do not receive them.
- **`ExcludeFocus`** — Prevents a subtree from receiving focus.

## 04 — Positioning Inside a Stack

- **`Positioned`** — Sets a Stack child’s left/top/right/bottom/width/height; must be under Stack.
- **`Positioned.fill`** — Makes a Stack child fill all available stack space.
- **`PositionedDirectional`** — Uses start/end rather than left/right for RTL-safe placement.
- **`Align`** — Often simpler than Positioned when only alignment is needed in a Stack.
- **`AnimatedPositioned`** — Implicitly animates a child’s Positioned values.
- **`Draggable`** — Lets a child be dragged; pair with DragTarget to accept drops.
- **`DragTarget`** — Receives data from a Draggable when dropped over it.

## 05 — Text, Icons, Images & Assets

- **`Text`** — Displays one styled run of text.
- **`RichText`** — Displays multiple text styles using a TextSpan tree.
- **`Text.rich`** — Convenience Text constructor for inline TextSpan content.
- **`SelectableText`** — Text users can select and copy.
- **`DefaultTextStyle`** — Provides default text style to descendant Text widgets.
- **`TextField`** — Editable text input; use controller, focusNode, decoration, keyboardType, validator via TextFormField.
- **`EditableText`** — Low-level editable text engine behind TextField; rarely needed directly.
- **`Icon`** — Displays an icon from an IconData source.
- **`IconButton`** — Tappable icon button with Material behavior and accessibility label.
- **`Image`** — Base image widget; use constructors below for common image sources.
- **`Image.asset`** — Displays an image bundled in your app assets.
- **`Image.network`** — Displays an image downloaded from a URL.
- **`Image.file`** — Displays an image from a local file (not web).
- **`Image.memory`** — Displays an image from bytes in memory.
- **`AssetImage`** — ImageProvider for a bundled asset.
- **`NetworkImage`** — ImageProvider for a network image.
- **`FadeInImage`** — Shows placeholder then fades in the loaded image.
- **`CircleAvatar`** — Circular avatar, often with image/background and initials.
- **`FlutterLogo`** — Flutter logo widget for demos; follow Flutter branding guidance.
- **`AssetBundle`** — Loads text, binary assets, and structured data packaged with the app.

## 06 — Styling, Surfaces, Painting & Effects

- **`DecoratedBox`** — Paints a Decoration (color, border, gradient, shadow) behind or in front of a child.
- **`ColoredBox`** — Efficient solid-color background for a child.
- **`Card`** — Material elevated/outlined container for grouped content.
- **`Material`** — Material surface that supplies ink effects, elevation, shape, and color.
- **`Ink`** — Paints decoration on a Material surface so ink splashes remain visible.
- **`InkWell`** — Material tap/hover splash response; requires a Material ancestor for visible ink.
- **`InkResponse`** — Lower-level flexible ink reaction, including circular splashes.
- **`ClipRRect`** — Clips child to a rounded rectangle.
- **`ClipOval`** — Clips child to an oval/circle.
- **`ClipPath`** — Clips child using a custom path.
- **`ClipRect`** — Clips child to a rectangle.
- **`Opacity`** — Applies opacity; AnimatedOpacity for transitions. May be costly in some cases.
- **`ShaderMask`** — Applies a shader, such as a gradient, to a child.
- **`ColorFiltered`** — Applies a color filter to a child.
- **`BackdropFilter`** — Filters content behind this widget; useful for blur/glass effects.
- **`Transform`** — Applies translation, scale, rotation, skew, or custom matrix at paint time.
- **`RotatedBox`** — Rotates in quarter turns during layout; preferable to Transform.rotate for 90° turns.
- **`CustomPaint`** — Paints custom graphics with a CustomPainter.
- **`RepaintBoundary`** — Isolates paint work; use only after profiling shows a repaint problem.
- **`PhysicalModel / PhysicalShape`** — Clips and paints a physical elevation/shadow shape.
- **`Divider / VerticalDivider`** — Thin Material separator in vertical/horizontal layouts.

## 07 — Buttons, Gestures & User Interaction

- **`ElevatedButton`** — Prominent filled Material button, suited to important actions.
- **`FilledButton`** — Material 3 filled button for primary actions.
- **`FilledButton.tonal`** — Material 3 softer filled button for secondary emphasis.
- **`OutlinedButton`** — Bordered Material button for secondary actions.
- **`TextButton`** — Low-emphasis text-only Material button.
- **`IconButton`** — Icon-only action button; provide tooltip and semantic label where appropriate.
- **`FloatingActionButton`** — Circular primary action button.
- **`SegmentedButton`** — Material 3 single- or multi-select segmented controls.
- **`DropdownButton`** — Classic Material dropdown menu.
- **`DropdownMenu`** — Material 3 dropdown/select field with improved menu behavior.
- **`MenuAnchor`** — Anchors a Material menu to a widget.
- **`MenuBar`** — Desktop-style horizontal menu bar.
- **`PopupMenuButton`** — Displays a popup menu from a button.
- **`GestureDetector`** — Detects taps, drags, long presses, pans, scales, and more without visual feedback.
- **`Listener`** — Low-level pointer event listener (down/move/up/hover).
- **`MouseRegion`** — Receives mouse enter/exit/hover and changes cursor.
- **`FocusableActionDetector`** — Combines focus, shortcuts/actions, hover, and enabled-state handling for custom controls.
- **`Dismissible`** — Swipe-to-dismiss a list item; supply a stable key.
- **`Tooltip`** — Small explanatory label on long press/hover.
- **`Shortcuts`** — Maps key combinations to Intents in a subtree.
- **`Actions`** — Maps Intents to executable Actions.
- **`CallbackShortcuts`** — Compact shortcut mapping for common keyboard actions.

## 08 — Forms, Selection & Pickers

- **`Form`** — Groups form fields and enables validation/save/reset through FormState or GlobalKey.
- **`TextFormField`** — TextField integrated with Form validation and saving.
- **`FormField`** — Base class for custom fields that participate in a Form.
- **`Checkbox`** — Binary checked/unchecked control; use tristate for a nullable third state.
- **`CheckboxListTile`** — Checkbox with built-in labeled list row.
- **`Radio`** — Single selection from a group; use RadioGroup where available in your SDK.
- **`RadioListTile`** — Radio with a labeled list row.
- **`Switch`** — On/off control.
- **`SwitchListTile`** — Switch with a labeled list row.
- **`Slider`** — Selects a single numeric value from a range.
- **`RangeSlider`** — Selects lower and upper values from a range.
- **`ChoiceChip`** — Selectable compact option, usually single-select.
- **`FilterChip`** — Selectable compact option, often multi-select.
- **`ActionChip`** — Compact action button styled as a chip.
- **`InputChip`** — Chip representing a complex item with selection/deletion/action options.
- **`Chip`** — Compact informational element, such as a contact or tag.
- **`showDatePicker`** — Material modal date picker function.
- **`showTimePicker`** — Material modal time picker function.
- **`showDateRangePicker`** — Material modal date-range picker function.
- **`Autocomplete`** — Text input with suggested options.
- **`RawAutocomplete`** — Lower-level customizable autocomplete.

## 09 — Lists, Grids & Standard Scrolling

- **`SingleChildScrollView`** — Scrolls one child; use for modest content, not huge or lazy lists.
- **`ListView`** — Linear scrollable list; use .builder for large/dynamic data.
- **`ListView.builder`** — Lazily creates list children as they become visible.
- **`ListView.separated`** — Lazy list with separators between items.
- **`GridView`** — Scrollable grid; use .builder for large/dynamic data.
- **`GridView.builder`** — Lazily creates grid items.
- **`PageView`** — Scrollable page-by-page content, such as onboarding or tabs.
- **`PageView.builder`** — Lazy PageView for many pages.
- **`ReorderableListView`** — List whose items users reorder by dragging.
- **`AnimatedList`** — List that animates item insertion/removal.
- **`AnimatedGrid`** — Grid that animates item insertion/removal.
- **`RefreshIndicator`** — Material pull-to-refresh wrapper around a vertical scrollable.
- **`Scrollbar`** — Visual scroll thumb for a scrollable.
- **`ScrollConfiguration`** — Changes scrolling behavior/overscroll effect for a subtree.
- **`ScrollController`** — Reads/controls scroll position; dispose when owned by State.
- **`NotificationListener<ScrollNotification>`** — Observes notifications bubbling up from scrolling children.
- **`DraggableScrollableSheet`** — Bottom-sheet-like scrollable that grows/shrinks as user drags.
- **`NestedScrollView`** — Coordinates outer and inner scroll views, often with SliverAppBar + tabs.
- **`CarouselView`** — Material carousel displaying scrollable items with dynamically changing size.

## 10 — Slivers: High-performance Custom Scroll Effects

- **`CustomScrollView`** — Scroll view composed of slivers; use for mixed collapsing headers, lists, grids, and fill areas.
- **`SliverAppBar`** — Collapsible/floating/pinned Material app bar sliver.
- **`SliverList`** — Lazy linear list sliver.
- **`SliverGrid`** — Lazy grid sliver.
- **`SliverToBoxAdapter`** — Places one normal box widget inside a sliver list.
- **`SliverPadding`** — Adds padding around a sliver.
- **`SliverPersistentHeader`** — Pinned/floating/shrinking custom header via a delegate.
- **`SliverFillRemaining`** — Fills remaining viewport space, optionally scrollable.
- **`SliverFillViewport`** — Sizes each child to fill the viewport.
- **`SliverAnimatedList`** — Animated insertion/removal for sliver list items.
- **`SliverAnimatedGrid`** — Animated insertion/removal for sliver grid items.
- **`SliverVisibility`** — Controls visibility of a sliver.
- **`SliverOffstage`** — Lays out a sliver without painting it.
- **`SliverOpacity`** — Applies opacity to a sliver.
- **`SliverLayoutBuilder`** — Builds a sliver based on sliver constraints.

## 11 — Navigation, Routes & Overlays

- **`Navigator`** — Manages a stack of routes/screens; use push, pop, pushNamed, or declarative routing.
- **`MaterialPageRoute`** — Standard Material page transition route.
- **`CupertinoPageRoute`** — iOS-style page transition route.
- **`PageRouteBuilder`** — Custom page route transition.
- **`RouteObserver`** — Observes route changes; useful for screen analytics/lifecycle integration.
- **`Router`** — Declarative routing foundation for URL/web/deep-link-aware navigation.
- **`MaterialApp.router`** — Material app configured with Router rather than simple routes.
- **`NavigationBar`** — Bottom navigation for top-level destinations.
- **`NavigationRail`** — Side navigation for wider windows.
- **`TabBar`** — Tab selector; usually needs DefaultTabController or a TabController.
- **`TabBarView`** — Pages corresponding to TabBar tabs.
- **`DefaultTabController`** — Convenience controller for a descendant TabBar and TabBarView.
- **`showDialog`** — Displays modal dialog above current route.
- **`AlertDialog`** — Standard Material confirmation/information dialog.
- **`SimpleDialog`** — Material dialog for choosing from a small set of options.
- **`showModalBottomSheet`** — Displays a modal sheet from the bottom.
- **`showBottomSheet`** — Displays a persistent sheet attached to a Scaffold.
- **`SnackBar`** — Brief Material message, usually shown via ScaffoldMessenger.
- **`ScaffoldMessenger`** — Shows SnackBars and MaterialBanners above current Scaffold.
- **`MaterialBanner`** — Persistent inline message/action near top of Scaffold.
- **`Overlay`** — Stack above routes for custom transient UI like coach marks or menus.
- **`OverlayEntry`** — One insertable item in an Overlay.

## 12 — Async, State Flow & Data-dependent UI

- **`FutureBuilder`** — Builds from an asynchronous Future snapshot; create the Future outside build when it should not restart.
- **`StreamBuilder`** — Builds from values/errors/states emitted by a Stream.
- **`ValueListenableBuilder`** — Rebuilds from a ValueListenable such as ValueNotifier.
- **`AnimatedBuilder`** — Rebuilds from any Listenable; useful for explicit animations and controllers.
- **`ListenableBuilder`** — Rebuilds from a Listenable without animation semantics.
- **`InheritedNotifier`** — InheritedWidget that notifies dependents when a Listenable changes.
- **`NotificationListener`** — Observes subtree notifications; different from state management.
- **`ChangeNotifier`** — Simple observable model object; not a widget, commonly used with provider-style patterns.
- **`ValueNotifier`** — Small ChangeNotifier that exposes one value.
- **`StatefulBuilder`** — Creates local setState for a small subtree, commonly inside dialogs; keep it limited.

## 13 — Animation & Motion

- **`AnimatedContainer`** — Implicitly animates Container properties such as size, color, padding, alignment, decoration.
- **`AnimatedOpacity`** — Implicitly fades child opacity.
- **`AnimatedAlign`** — Implicitly animates alignment.
- **`AnimatedPadding`** — Implicitly animates padding.
- **`AnimatedPositioned`** — Implicitly animates a Positioned Stack child.
- **`AnimatedSize`** — Animates when child size changes.
- **`AnimatedSwitcher`** — Animates when a child is replaced; use keys to distinguish same-type children.
- **`AnimatedCrossFade`** — Cross-fades between two children and animates size.
- **`AnimatedScale / AnimatedRotation / AnimatedSlide`** — Implicitly animate transform-like scale, rotation, or offset.
- **`TweenAnimationBuilder`** — Builds a simple implicit tween without managing a controller.
- **`Hero`** — Shared-element transition between routes using matching tags.
- **`AnimationController`** — Controls explicit animation timeline; dispose it in State.
- **`Animation`** — Read-only animated value driven by controller/tween.
- **`Tween`** — Maps normalized animation progress to a value range.
- **`CurvedAnimation`** — Applies a curve to an animation.
- **`FadeTransition`** — Explicit animation of opacity.
- **`ScaleTransition`** — Explicit animation of scale.
- **`RotationTransition`** — Explicit animation of rotation.
- **`SlideTransition`** — Explicit animation of fractional offset.
- **`SizeTransition`** — Explicit animation of size along one axis.
- **`PositionedTransition`** — Explicit animation of a Stack child’s relative rectangle.
- **`DecoratedBoxTransition`** — Explicit animation between decorations.
- **`AnimatedModalBarrier`** — Animated barrier that blocks interactions behind modal UI.
- **`TickerMode`** — Disables ticking animations in an inactive subtree.

## 14 — Theme, Responsive Design & Internationalization

- **`Theme`** — Supplies Material design values to descendants.
- **`ThemeData`** — Material theme configuration: color scheme, typography, components, visual density.
- **`ColorScheme`** — Semantic Material color palette; prefer it over scattered literal colors.
- **`TextTheme`** — Named text styles for consistent typography.
- **`IconTheme`** — Default icon color, opacity, and size for descendants.
- **`DefaultTextStyle`** — Default text style for descendants.
- **`MediaQuery`** — Device/window data including size, padding, accessibility and text scale.
- **`LayoutBuilder`** — Responds to parent constraints—usually better than only checking screen width.
- **`Directionality`** — Supplies text direction (LTR/RTL) to descendants.
- **`Localizations`** — Provides localized resources to the widget subtree.
- **`Localizations.override`** — Overrides locale/resources for a subtree.
- **`MaterialApp.localizationsDelegates`** — Registers localization delegates in a Material app.
- **`MediaQuery.textScalerOf`** — Reads user text scaling preference; avoid hard-coding text size behavior.

## 15 — Accessibility, Focus & Keyboard

- **`Semantics`** — Adds a meaningful accessibility label, role, value, hint, or action to a subtree.
- **`MergeSemantics`** — Combines descendant semantics into one accessible node.
- **`ExcludeSemantics`** — Removes descendant semantics from assistive technologies.
- **`ExcludeFocus`** — Prevents focus for a subtree.
- **`Focus`** — Makes a widget/subtree focusable and handles focus changes.
- **`FocusScope`** — Groups focusable widgets and controls focus traversal.
- **`FocusTraversalGroup`** — Defines traversal order for a group of focusable widgets.
- **`FocusTraversalOrder`** — Overrides traversal order of an individual widget.
- **`KeyboardListener`** — Receives raw keyboard events for focused hardware keyboard input.
- **`Shortcuts`** — Maps keyboard shortcuts to semantic Intents.
- **`Actions`** — Maps Intents to Actions that execute behavior.
- **`FocusableActionDetector`** — Accessible base for custom buttons: focus, hover, shortcuts, and enabled state.
- **`Tooltip`** — Explains controls on hover or long press.

## 16 — Cupertino (iOS/macOS Style)

- **`CupertinoApp`** — App shell with iOS-style defaults.
- **`CupertinoPageScaffold`** — Basic iOS-style page with navigation bar and child content.
- **`CupertinoNavigationBar`** — iOS-style top navigation bar.
- **`CupertinoSliverNavigationBar`** — Large-title/sliver iOS navigation bar.
- **`CupertinoTabScaffold`** — iOS bottom-tab application shell.
- **`CupertinoTabBar`** — Bottom tab selector for CupertinoTabScaffold.
- **`CupertinoTabView`** — Independent Navigator for a Cupertino tab.
- **`CupertinoButton`** — iOS-style button.
- **`CupertinoTextField`** — iOS-style text field.
- **`CupertinoSwitch`** — iOS-style switch.
- **`CupertinoSlider`** — iOS-style numeric slider.
- **`CupertinoPicker`** — iOS wheel picker.
- **`CupertinoDatePicker`** — iOS date/time wheel picker.
- **`CupertinoActionSheet`** — iOS action sheet, usually shown by showCupertinoModalPopup.
- **`CupertinoAlertDialog`** — iOS confirmation/information dialog.
- **`CupertinoDialogAction`** — Action button used in CupertinoAlertDialog.
- **`CupertinoActivityIndicator`** — iOS loading spinner.
- **`CupertinoListSection`** — iOS grouped-list section.
- **`CupertinoListTile`** — iOS-style list row.
- **`CupertinoScrollbar`** — iOS-style scrollbar.
- **`CupertinoContextMenu`** — Long-press context menu with preview/action UI.
- **`CupertinoSearchTextField`** — iOS-style search field.

## 17 — Platform, Desktop & Adaptive Helpers

- **`PlatformView`** — Embeds a native platform view; use deliberately because it has performance/interaction trade-offs.
- **`AndroidView`** — Embeds an Android native view.
- **`UiKitView`** — Embeds an iOS UIKit view.
- **`PlatformMenuBar`** — Native macOS menu bar integration.
- **`MenuBar`** — Flutter Material desktop menu bar.
- **`WindowSizeClass`** — Concept, not a core widget: adapt layout based on available width/height, normally via LayoutBuilder.
- **`SelectionArea`** — Makes an entire subtree text-selectable on supported platforms.
- **`InteractiveViewer`** — Pan/zoom a child with gestures; useful for diagrams/maps/canvases.
- **`DataTable`** — Material table for small/medium datasets; use paginated/lazy patterns for large data.
- **`PaginatedDataTable`** — DataTable with pagination.
- **`TableView`** — Two-dimensional scrollable table view where supported by current Flutter SDK.

## 18 — Loading, Feedback & Common Status UI

- **`CircularProgressIndicator`** — Circular indeterminate or determinate progress indicator.
- **`LinearProgressIndicator`** — Horizontal progress indicator.
- **`RefreshProgressIndicator`** — Material spinner typically used by RefreshIndicator.
- **`AdaptiveProgressIndicator`** — Use adaptive constructors/components where platform-specific appearance matters.
- **`Badge`** — Small Material indicator/count attached to another widget.
- **`Banner`** — Diagonal ribbon label over a child.
- **`Tooltip`** — Explains a control without taking permanent layout space.
- **`SnackBar`** — Short feedback message.
- **`MaterialBanner`** — Persistent feedback/action message near top of a screen.
- **`AlertDialog`** — Blocks for acknowledgement, confirmation, or a focused decision.
- **`Empty state pattern`** — Usually a centered Column with Icon/Image, Text, explanation, and a retry/action button—not a single built-in widget.

## 19 — Practical Parent/Child Rules

- **`Expanded / Flexible / Spacer → Row, Column, or Flex`** — These are ParentDataWidgets and require a Flex ancestor without render-object widgets in between.
- **`Positioned → Stack`** — Positioned must be a descendant of Stack; do not place it in Row/Column.
- **`Sliver* widgets → CustomScrollView`** — Use slivers only in sliver-aware parents, usually CustomScrollView.
- **`TabBar + TabBarView → DefaultTabController or TabController`** — Both must use the same controller and have matching tab/page counts.
- **`ScaffoldMessenger → Scaffold / MaterialApp`** — Use it to show SnackBars rather than calling deprecated Scaffold.of patterns.
- **`InkWell → Material`** — Ink splash needs a Material ancestor; use Ink for decorated surfaces.
- **`FormField / TextFormField → Form`** — A Form is required when you want group validation/save/reset.
- **`Dismissible → stable Key`** — Each list item needs a unique key so Flutter tracks the correct item.
- **`ReorderableListView → stable keys`** — Every reorderable child needs a key.
- **`ListView inside Column`** — Wrap ListView in Expanded/Flexible or give it a bounded height to avoid unbounded-height errors.
- **`SingleChildScrollView + Column`** — Use for short content; do not put an unbounded ListView inside it without careful constraints.

## 20 — Fast Selection Guide

- **`Need a normal page?`** — Scaffold + SafeArea + AppBar + body.
- **`Need horizontal/vertical arrangement?`** — Row / Column; add Expanded, Flexible, Spacer, or Wrap as needed.
- **`Need a responsive breakpoint?`** — LayoutBuilder first; use MediaQuery for global window/device properties.
- **`Need a large list?`** — ListView.builder; use CustomScrollView + SliverList when mixing lists with sliver headers/grids.
- **`Need fixed card-like content?`** — Card or Container/DecoratedBox with Material/Ink interactions.
- **`Need a button?`** — FilledButton for primary, OutlinedButton for secondary, TextButton for low emphasis, IconButton for icon action.
- **`Need a form?`** — Form + TextFormField/other FormField widgets + validator.
- **`Need async data?`** — FutureBuilder for a one-time Future; StreamBuilder for ongoing updates.
- **`Need a simple animation?`** — Start with implicit widgets: AnimatedContainer, AnimatedOpacity, AnimatedSwitcher.
- **`Need custom animation control?`** — AnimationController + Transition widgets/AnimatedBuilder.
- **`Need iOS-native visual language?`** — Use CupertinoApp and Cupertino widgets consistently for that subtree/app.
- **`Need custom drawing?`** — CustomPaint + CustomPainter, after exhausting composition with standard widgets.

## Imports you will use most

```dart
import 'package:flutter/material.dart';    // Material + widgets + painting
import 'package:flutter/cupertino.dart';   // Cupertino widgets
```

## High-value habits

- Use `const` constructors wherever possible.
- Prefer `ListView.builder` and `GridView.builder` for large or unknown-length collections.
- Use `LayoutBuilder` for responsive UI inside a layout; use `MediaQuery` for device/window-level settings.
- Keep side effects (network calls, controllers, navigation) out of `build()`.
- Add semantic labels, tooltips, keyboard support, and visible focus states to custom controls.
- Profile before adding `RepaintBoundary`, intrinsic sizing, or platform views for performance reasons.

## Official source categories (for SDK-version checks)

- Flutter Widget Catalog: `docs.flutter.dev/ui/widgets`
- Widget API reference: `api.flutter.dev/flutter/widgets/`
- Material widgets: `docs.flutter.dev/ui/widgets/material`
- Cupertino widgets: `docs.flutter.dev/ui/widgets/cupertino`

