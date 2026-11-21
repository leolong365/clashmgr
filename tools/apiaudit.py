import os, re, sys, json

SRC = os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'ios', 'ClashMgr')
SRC = os.path.abspath(SRC)

CORE = ['Core/YAMLValue.swift','Core/YAMLLexer.swift','Core/YAMLParser.swift','Core/YAMLEmitter.swift',
        'Models/ProxyModels.swift','Models/RuleMatcher.swift','Models/MihomoConfig.swift',
        'Models/Subscription.swift','Services/AppSettings.swift','Services/ConfigStore.swift',
        'Services/SubscriptionFetcher.swift','Services/LatencyTester.swift','Services/Exporter.swift',
        'App/AppState.swift']

VIEWS = ['App/ClashMgrApp.swift'] + ['Views/%s.swift' % n for n in
    ['Components','SubscriptionsView','AddSubscriptionView','ProxiesView','RulesView',
     'RuleTesterView','SettingsView','ExportView']]

def read(rel):
    with open(os.path.join(SRC, rel), encoding='utf-8') as f:
        return f.read()

core_text = '\n'.join(read(r) for r in CORE)
view_text = '\n'.join(read(r) for r in VIEWS)

# public/internal declarations in core
decls = {}
for m in re.finditer(r'\b(?:public\s+|internal\s+)?(?:final\s+)?(?:class|struct|enum|protocol)\s+([A-Za-z_]\w*)', core_text):
    decls.setdefault(m.group(1), set())

# members declared inside core: func/var/let/case
members = set()
for m in re.finditer(r'\b(?:public\s+|private\s+|fileprivate\s+|internal\s+|static\s+|class\s+|override\s+|@MainActor\s+|mutating\s+|lazy\s+|final\s+)*(?:func|var|let|case)\s+([A-Za-z_]\w*)', core_text):
    members.add(m.group(1))

# also enum cases written as identifiers in case lists
for m in re.finditer(r'\bcase\s+([A-Za-z_]\w*)', core_text):
    members.add(m.group(1))

print('=== declared types (%d) ===' % len(decls))
print(', '.join(sorted(decls)))
print()

# find identifiers used in views that look like they come from core:
# pattern: TypeName.member  OR  .member
type_member_calls = set()
for m in re.finditer(r'\b([A-Z][A-Za-z0-9_]*)\.([a-zA-Z_]\w*)', view_text):
    t, mem = m.group(1), m.group(2)
    if t in decls:
        type_member_calls.add((t, mem))

missing = []
for (t, mem) in sorted(type_member_calls):
    if mem not in members:
        missing.append((t, mem))

print('=== static/type member calls on core types: %d checked ===' % len(type_member_calls))
if missing:
    print('*** POSSIBLY MISSING MEMBERS ***')
    for t, mem in missing:
        print('  %s.%s' % (t, mem))
else:
    print('all resolved')
print()

# instance member usage via chained access on known-typed vars is hard; instead collect
# every ".foo(" call name in views and check it exists somewhere in core OR is a SwiftUI/Foundation name
calls = set(re.findall(r'\.([a-zA-Z_]\w*)\s*\(', view_text))
swiftui_ok = set('''init body frame padding foregroundColor foregroundStyle background overlay border cornerRadius
font fontWeight bold italic lineLimit minimumScaleFactor truncationMode padding clipping mask shadow opacity
blur scaleEffect rotationEffect offset animation transition navigationTitle navigationBarTitleDisplayMode
toolbar sheet alert confirmDialog confirmationDialog popover fullScreenCover onAppear onDisappear onChange onOpenURL
task refreshable listStyle accentColor tint buttonStyle labelStyle toggleStyle pickerStyle textFieldStyle
environmentObject environment sizeCategory dynamicTypeSize colorScheme keyboardType textInputAutocapitalization
submitLabel safeAreaInset searchable scrollContentBackground disableAutocase autocorrectionDisabled
listRowInsets listRowBackground listRowSeparator swipeActions contextMenu gesture onTapGesture onLongPressGesture
frame minLength maxWidth idealWidth maxHeight minHeight spacedBy lineSpacing tabItem tag selection
navigationDestination NavigationLink NavigationStack NavigationView NavigationSplitView ScrollView VStack HStack
ZStack LazyVStack LazyVGrid Grid VStack spacing ForEach Section Group Divider Spacer Image Text Button Toggle
Picker Slider ProgressView Label Menu DatePicker Stepper Form List NavigationStack TabView
count enumerated map filter sorted first last contains prefix suffix joined isEmpty
appendingPathComponent deletingLastPathComponent standardizing lowercased uppercased trimmed
trimmingCharacters hasPrefix hasSuffix components separated split replacedOccurrences
formatted timeIntervalSinceNow localizedDescription range upperBound lowerBound
valueForKey allCases rawValue id hashValue description
randomElement min max abs round floor ceil sqrt pow
insert remove removeAll append insertContentsOf
startAccessingSecurityScopedResource stopAccessingSecurityScopedResource
loadData representation conformingTo
image from createCGImage outputImage transformed
makeUIViewController updateUIViewController makeCoordinator
sheetWithDetents presentationDetents presentationDragIndicator
submitLabel submitLabel2 focused focusedValue scrollDismissesKeyboard
symbolRenderingMode imageScale resizable interpolation antialiased clippingShape
aspectRatio contentShape allowsHitTesting hidden disabled
openURL canOpenURL absoluteString scheme host path query
'''.split())
unk = sorted(c for c in calls if c not in members and c not in swiftui_ok)
print('=== call names in views not obviously known (%d) ===' % len(unk))
print(', '.join(unk))
