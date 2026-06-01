<div dir="rtl">

<h1 align="center">Chatmux</h1>
<p align="center">تفرع شخصي من <a href="https://github.com/manaflow-ai/cmux">cmux</a> مع تكامل أصلي مع Claude وأدوات سير عمل GitLab وتحسينات أخرى للراحة.</p>

<p align="center">
  <a href="#التثبيت-من-المصدر">التثبيت من المصدر</a> · <a href="#ما-يضيفه-هذا-التفرع">ما يضيفه هذا التفرع</a> · <a href="#المزامنة-مع-upstream">المزامنة مع upstream</a> · <a href="https://github.com/manaflow-ai/cmux">cmux upstream</a>
</p>

---

Chatmux مبني فوق [manaflow-ai/cmux](https://github.com/manaflow-ai/cmux) — وهو طرفية macOS مبنية على Ghostty مع علامات تبويب رأسية وإشعارات لوكلاء البرمجة بالذكاء الاصطناعي. كل ما هو موثق في [README upstream](https://github.com/manaflow-ai/cmux/blob/main/README.ar.md) لا يزال ينطبق: حلقات الإشعارات، المتصفح المدمج، علامات التبويب الرأسية+الأفقية، SSH، Claude Code Teams، استعادة الجلسة، CLI/socket API الخاص بـ cmux، إلخ.

تغطي هذه الوثيقة فقط ما يضيفه Chatmux فوق ذلك.

## ما يضيفه هذا التفرع

### لوحة Claude Chat

لوحة Claude SDK داخل التطبيق تعمل داخل أي جزء — تأخذ دليل العمل الخاص بمساحة العمل وتبث الردود وتحافظ على سجل المحادثة لكل surface.

- تكامل MCP: نافذة منبثقة **MCP Manager** مدمجة لتسجيل/إدارة خوادم MCP و health prober يعرض حالة الخادم بشكل مضمن
- سجل أوامر slash: عرّف أوامر slash مخصصة لكل دردشة
- Status line runner: المهام طويلة الأمد تعرض سطر حالة مباشر في رأس الدردشة
- سجل الجلسة: كل دردشة تُسجل على القرص ويمكن استئنافها عبر إعادة تشغيل cmux
- محرك قواعد الأذونات: قم بتكوين الأدوات التي يمكن للدردشة استدعاؤها تلقائيًا وأيها يتطلب تأكيدًا

إجراء شريط علامات التبويب المدمج `cmux.newClaudeChat` يفتح Claude Chat جديدًا في الجزء المركّز.

### تكامل GitLab

لوحة الشريط الجانبي الأيمن تقتصر على مشروع GitLab الخاص بمساحة العمل:

- قائمة **Merge Requests** مع فلاتر للمعيّن/المؤلف وفتح بنقرة واحدة
- قائمة **Issues** بنفس نظام الفلترة، مدعومة بـ `GitLabIssueFiltersStore`
- قائمة **Pipelines** مع مؤشرات الحالة
- قائمة **Releases**
- عارض **MR Discussions** مع دعم three-way diff (`MRDiscussions.swift`)
- مخازن diff refs و merged-tree حتى يعرف عارض diff دائمًا SHAs base/target الصحيحة

يستخدم تكوينك المحلي لـ `glab` / `git` — لا حاجة إلى بيانات اعتماد إضافية.

### عارض Git diff

نافذة diff مستقلة لأي commit أو فرع أو working tree (`GitDiffWindow.swift`):

- `DiffCodeTextView` جنبًا إلى جنب و `DiffThreeWayCodeTextView` ثلاثي الاتجاه
- محرك `LCSDiff` مخصص و `SyntaxHighlighter` لـ Swift و TypeScript و Markdown وغيرها
- مشترك مع عارض مناقشات MR في GitLab

### الشريط الجانبي Workspace Notes

ملاحظات markdown لكل مساحة عمل تسافر مع مساحة العمل:

- فتحة الشريط الجانبي مثبتة بجوار لوحة GitLab (الشريط الجانبي الأيمن)
- أرشفة تلقائية عند إغلاق مساحة العمل — الملاحظات لا تُفقد بصمت أبدًا (راجع شبكة الأمان في `TabManager.closeWorkspace`)
- نافذة **Notes Manager** مستقلة (`WorkspaceNotesManagerWindowController`) لتصفح واستعادة الملاحظات المؤرشفة عبر جميع مساحات العمل
- إجراء شريط علامات التبويب المدمج `cmux.toggleNotes` لتبديل الشريط الجانبي من لوحة المفاتيح أو أمر مخصص

### إعدادات مسبقة للجلسة

احفظ تخطيط الجلسة الحالي (الأجزاء، surfaces، الطرفيات، عناوين URL للمتصفح، حالة الشريط الجانبي) كإعداد مسبق مسمى، ثم أعد إنشاءه لاحقًا:

- حفظ: `File → Save Session as Preset…` (أو لوحة الأوامر)
- تحميل: `File → Load Preset → …`
- تحديث: `File → Update Current Preset`
- التخزين محدد النطاق بواسطة bundle-id بحيث يحتفظ cmux و Chatmux بمجموعات إعدادات مسبقة مستقلة (`SessionPresetSchema.defaultDirectoryURL`)

### النوافذ المنبثقة MCP Manager + Background Shells

نافذتان منبثقتان يمكن الوصول إليهما من شريط العنوان:

- **MCP Manager** — اكتشف خوادم MCP المستخدمة من قبل دردشة Claude، فعّلها، عطّلها، وتحقق من حالتها
- **Background Shells** — تصفح الـ shells المنفصلة التي أطلقتها الدردشة / surface API، ألق نظرة على مخرجاتها، واستأنفها في surface مرئي

### Open in Sourcetree

إجراء شريط علامات تبويب مدمج جديد `cmux.openInSourcetree` بجوار `openInFinder` و `openInIDE`. يفتح دليل العمل الخاص بالجزء المركّز في [Atlassian Sourcetree](https://www.sourcetreeapp.com/) (يصدر صوت تنبيه إذا لم يكن Sourcetree مثبتًا في `/Applications/Sourcetree.app`).

قم بتوصيله في تخطيط الأزرار الخاص بك في `~/.config/cmux/cmux.json` أو اعتمد على شريط علامات التبويب الافتراضي.

### سكريبت التثبيت الذاتي

`scripts/install-fork.sh` يبني تكوين Release ويوقع ad-hoc بـ bundle id مميز وينسخ الحزمة إلى `/Applications/Chatmux.app` بحيث تعمل جنبًا إلى جنب مع cmux upstream:

```bash
rm -rf ghostty/zig-pkg && CMUX_SKIP_ZIG_BUILD=1 ./scripts/install-fork.sh --launch
```

الهوية الافتراضية:

| الحقل | القيمة |
|---|---|
| اسم التطبيق | `Chatmux` |
| Bundle id | `com.cmuxterm.app.fork` |
| مسار التثبيت | `/Applications/Chatmux.app` |

استبدل بـ `--name` أو `--bundle-id` أو `--dest` إذا كنت تريد هوية مختلفة (على سبيل المثال، بناء staging). تثبيت bundle id عبر `codesign -i <bundle-id>` أمر بالغ الأهمية لاستقرار أذونات macOS TCC — بدونه، تتم إعادة طلب أذونات Documents/App Management في كل عملية تشغيل.

مساحات العمل ولقطات الجلسة والإعدادات المسبقة والملاحظات وتكوين MCP ومنح TCC كلها مفهرسة بواسطة `CFBundleIdentifier`، لذلك تستمر عبر إعادات التثبيت طالما احتفظت بنفس bundle id.

### أمر slash `/sync-upstream`

أمر slash مخصص لـ Claude Code (في `.claude/commands/`) يقوم بأتمتة رقصة الدمج chatmux ↔ upstream:

- Fast-forward `main` إلى `manaflow-ai/cmux:main`
- يعكس مؤشر الوحدة الفرعية `vendor/bonsplit` المطابق إلى bonsplit fork الخاص بك
- ينشئ فرعًا مؤقتًا `chatmux-merge-<timestamp>` ويدمج upstream فيه
- يحل تلقائيًا تعارضات `cmux.xcodeproj/project.pbxproj` بدمج كلا الجانبين + إزالة التكرار بواسطة ID
- يتوقف ويعرض أي تعارض في `Sources/` أو `Packages/` أو `Resources/` للحل البشري
- يدفع الفرع المؤقت وينتظر تأكيد البناء قبل fast-forward `chatmux`

راجع `.claude/commands/sync-upstream.md` لسير العمل الكامل و `scripts/sync-upstream-resolve.py` لمساعد pbxproj.

## التثبيت من المصدر

Chatmux لا يُنشر كـ DMG. ابنِ وثبت بسكريبت التفرع:

```bash
# استنساخ مع الوحدات الفرعية
git clone --recurse-submodules https://github.com/Shyri/cmux.git
cd cmux

# الإعداد لمرة واحدة (يجلب وحدة Ghostty الفرعية، GhosttyKit، إلخ)
./scripts/setup.sh

# بناء Release + التثبيت في /Applications/Chatmux.app + التشغيل
rm -rf ghostty/zig-pkg && CMUX_SKIP_ZIG_BUILD=1 ./scripts/install-fork.sh --launch
```

لماذا البادئة `rm -rf ghostty/zig-pkg && CMUX_SKIP_ZIG_BUILD=1`؟ محليًا نقوم بتشغيل Zig 0.16، لكن Ghostty يتطلب 0.15.2. تخطي بناء zig يجبر السكريبت على استخدام GhosttyKit.xcframework المبني مسبقًا من إصدارات `manaflow-ai/ghostty`. تنظيف `zig-pkg/` يحافظ على نظافة build key بحيث يعمل cache hit للبناء المسبق.

## المزامنة مع upstream

```bash
# داخل جلسة Claude Code في هذا المستودع:
/sync-upstream
```

أمر slash يتعامل مع سير عمل الدمج الكامل بما في ذلك فرز التعارضات. راجع [ما يضيفه هذا التفرع → /sync-upstream](#أمر-slash-sync-upstream).

للدمج اليدوي، اتبع نفس الخطوات في `.claude/commands/sync-upstream.md`.

## اختصارات لوحة المفاتيح

تعمل جميع اختصارات cmux upstream دون تغيير. راجع [README upstream](https://github.com/manaflow-ai/cmux/blob/main/README.ar.md#keyboard-shortcuts) للجدول الكامل. الاختصارات الحصرية لـ Chatmux قابلة للتكوين في Settings → Keyboard Shortcuts وتظهر في `~/.config/cmux/cmux.json` مثل أي اختصار cmux آخر.

## شكر وتقدير

Chatmux هو تفرع من [cmux](https://github.com/manaflow-ai/cmux) من [Manaflow](https://manaflow.com). جميع ميزات upstream ومحرك الطرفية ملكية لهم — يرجى تقديم نجمة للمشروع الأصلي ودعمه.

## الترخيص

نفس ترخيص upstream: [GPL-3.0-or-later](LICENSE).

</div>
