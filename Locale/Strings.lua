local _, RG = ...
local L = RG.Register("Locale", {})

L.enUS = {
    addon = "RivalGuard", nearby = "Nearby", settings = "Settings", overview = "Overview",
    alerts = "Alerts", appearance = "Appearance", profiles = "Profiles", journal = "Journal", support = "Support",
    close = "Close", back = "Back", next = "Next", previous = "Previous", all = "All classes", reset = "Reset",
    enabled = "Enable RivalGuard", enabledTip = "Record available enemy sightings and apply your alert rules.",
    active = "Watching", paused = "Paused", disabled = "Disabled", muted = "Sound off", pause = "Pause 10 min",
    resume = "Resume", mute = "Mute", unmute = "Sound on", demo = "Preview", demoTip = "Preview sample contacts and alerts. No real encounter is recorded.",
    noEnemies = "No opponents seen", noEnemiesHelp = "RivalGuard watches information the game makes available.",
    unknownPlayer = "Unknown player", unknownClass = "Unknown class", unknown = "Unknown", visible = "In view",
    lastSeen = "Seen %s ago", seconds = "%ds", minutes = "%dm", hours = "%dh", days = "%dd", watched = "Watch list", avoided = "Avoid list", ignored = "Ignored",
    targeting = "Targeting you", stealth = "Stealth observed", possibleStealth = "Possible stealth", rangeUnknown = "Range unknown",
    rangeWithin = "Within %d yd", rangeBeyond = "Over %d yd", rangeBracket = "%d–%d yd",
    listHint = "Click a row for details. Drag the header when unlocked.",
    rowHint = "Open details and personal notes.", moreContacts = "%d more · use the mouse wheel",
    showList = "Show nearby list", showListTip = "Keep a compact list of current and recent sightings.",
    showUnknown = "Show players with unknown class", showUnknownTip = "Missing class information is not treated as a safe player.",
    displayClasses = "Classes shown in the list", alertClasses = "Classes that trigger ordinary alerts",
    classesTip = "Class filters affect ordinary sightings. Watch list and important events follow their own settings.",
    watch = "Watch", avoid = "Avoid", ignore = "Ignore", removeList = "Remove from list", note = "Personal note", saveNote = "Save note",
    details = "Player details", selectContact = "Select a player in Nearby or Journal to view details.",
    identityUnknown = "Personal lists need a readable identity. This anonymous sighting cannot be saved.",
    noTarget = "Rows open details; they do not change your target.",
    reason = "Evidence", source = "Sources", observed = "Observed by your client", notSeen = "No longer in view",
    selectedProfile = "Active profile", preset = "Ready-made setup", balanced = "Balanced", farming = "Farming", quiet = "Quiet", battleground = "Battleground",
    balancedTip = "All classes, useful alerts and limited repeats.", farmingTip = "Ordinary alerts focus on Rogues, Hunters and Druids.",
    quietTip = "Visual awareness without sounds.", battlegroundTip = "Fewer ordinary alerts in busy battlegrounds.",
    presetHelp = "Create a profile from a setup. Your existing profile stays available.",
    createProfile = "Create profile", profileName = "New profile name", useProfile = "Use", deleteProfile = "Delete", noProfiles = "No profiles available",
    profileDeleted = "Profile deleted.", profileCreated = "Profile created.", profileUsed = "Profile selected.",
    profileError = "The profile could not be changed. Choose a valid, unique name.",
    deleteConfirm = "Click Delete again to remove this profile.",
    alertsEnabled = "Enable alerts", sound = "Play alert sounds", banner = "Show alert banner", soundChannel = "Sound channel",
    soundChannelTip = "Master remains audible when individual sound channels are lowered; the game's master mute still applies.",
    master = "Master", sfx = "Sound effects", music = "Music", ambience = "Ambience", dialog = "Dialog",
    alertStealth = "Observed stealth", alertStealthTip = "Warn only when a supported stealth event is readable. A disappearing nameplate alone is not proof.",
    alertTargeting = "Opponent targeting you", alertTargetingTip = "Warn when a readable enemy target matches you. Being targeted is not proof of an attack.",
    watchedOnly = "Only alert on personal lists", watchedOnlyTip = "Limit ordinary sightings to players on your watch or avoid list.",
    muteOrdinary = "Silence ordinary sightings", muteOrdinaryTip = "Keep personal-list and important event alerts available.",
    cooldown = "Repeat delay", cooldownTip = "Seconds before an ordinary alert for the same player can repeat.",
    returnAfter = "New encounter after", returnAfterTip = "How long someone must be absent before a new ordinary sighting can alert.",
    rangeFilter = "Limit ordinary alerts by range", rangeFilterTip = "Range can be an estimate or unavailable. This does not extend detection distance.",
    rangeYards = "Range threshold (yards)", rangePolicy = "If the estimate crosses the threshold", possible = "Alert if possibly close", confirmed = "Only if confirmed close",
    unknownRange = "Alert when range is unknown", contexts = "Where RivalGuard runs", world = "Open world", arena = "Arena", instance = "Dungeons and raids",
    sanctuary = "Sanctuaries", resting = "Rest areas", flight = "While on a flight path",
    showBadges = "Class badges on enemy nameplates", showBadgesTip = "Decorate available enemy nameplates without changing Blizzard health bars or targeting.",
    locked = "Lock nearby position", highContrast = "High contrast", reducedMotion = "Reduced motion", streamer = "Hide player names in RivalGuard",
    streamerTip = "Use session aliases in RivalGuard. Blizzard UI, chat and other addons are unaffected.",
    textSize = "Nearby text size", scale = "Nearby scale", maxRows = "Visible rows", resetPosition = "Reset window positions",
    previewBanner = "Preview alert", previewList = "Preview contacts", appearanceHelp = "Changes apply immediately. Drag the unlocked list or preview banner to move it.",
    nearbyTitle = "Nearby opponents", alertTitle = "Opponent spotted", watchTitle = "Watch list player", stealthTitle = "Stealth observed",
    targetingTitle = "Opponent targeting you", waveTitle = "Several opponents spotted", waveBody = "%d opponents detected close together",
    demoLabel = "Preview", demoRogue = "Sample Rogue", demoHunter = "Sample Hunter", demoMage = "Sample Mage", demoWatch = "Sample rival",
    badgeTip = "RivalGuard class badge", status = "Detection status", sensorLimited = "Some detection information is unavailable",
    statusHelp = "RivalGuard cannot see fully hidden players. No sightings does not mean an area is safe.",
    supportHelp = "Copy a diagnostic report when something looks wrong. Reports are generated locally; nothing is sent automatically.",
    diagnostics = "Copy diagnostics", copyTitle = "Diagnostic report", copyHelp = "Select the text and press Ctrl+C. Close this window when finished.",
    reportUnavailable = "Diagnostics are not available yet.", records = "Recent records", emptyJournal = "No saved encounters yet",
    journalHelp = "Recent sightings and your personal lists. Selecting a record opens details.",
    noJournalAPI = "The encounter journal is not available in this build.", noProfileAPI = "Profile management is not available in this build.",
    noListAPI = "Personal list editing is not available in this build.", nothingSelected = "No player selected",
    saved = "Saved.", saveFailed = "Could not save this record.", settingsHint = "Useful defaults are already active. Adjust only what you need.",
    classSelection = "%d selected", language = "Language", automatic = "Automatic", english = "English", russian = "Русский",
    languageTip = "Choose the language for RivalGuard. Other addons and the game are unchanged.",
    sensorReady = "Detection is running", sensorUnavailable = "Detection is unavailable", noData = "No data available",
    nameplatesOff = "Enemy nameplates are off. Enable them in the game settings for more sightings.",
    settingUnavailable = "Unavailable on this client", error = "Something could not be completed.",
}

L.ruRU = {
    addon = "RivalGuard", nearby = "Рядом", settings = "Настройки", overview = "Обзор",
    alerts = "Оповещения", appearance = "Внешний вид", profiles = "Профили", journal = "Журнал", support = "Поддержка",
    close = "Закрыть", back = "Назад", next = "Далее", previous = "Назад", all = "Все классы", reset = "Сбросить",
    enabled = "Включить RivalGuard", enabledTip = "Замечать доступных противников и применять ваши правила оповещений.",
    active = "Наблюдение", paused = "Пауза", disabled = "Выключен", muted = "Без звука", pause = "Пауза 10 мин",
    resume = "Продолжить", mute = "Без звука", unmute = "Включить звук", demo = "Пример", demoTip = "Показать примеры игроков и оповещений. Реальные встречи не записываются.",
    noEnemies = "Противники не замечены", noEnemiesHelp = "RivalGuard использует только информацию, доступную игре.",
    unknownPlayer = "Неизвестный игрок", unknownClass = "Класс неизвестен", unknown = "Неизвестно", visible = "В поле зрения",
    lastSeen = "Замечен %s назад", seconds = "%d с", minutes = "%d мин", hours = "%d ч", days = "%d дн", watched = "Наблюдение", avoided = "Опасный игрок", ignored = "Игнорируется",
    targeting = "Выбрал вас целью", stealth = "Замечена скрытность", possibleStealth = "Возможна скрытность", rangeUnknown = "Расстояние неизвестно",
    rangeWithin = "До %d ярдов", rangeBeyond = "Далее %d ярдов", rangeBracket = "%d–%d ярдов",
    listHint = "Нажмите на игрока для подробностей. Незакреплённое окно можно перетащить за заголовок.",
    rowHint = "Открыть сведения и личную заметку.", moreContacts = "Ещё %d · прокрутите колёсиком",
    showList = "Показывать список противников", showListTip = "Компактный список игроков, замеченных сейчас и недавно.",
    showUnknown = "Показывать игроков с неизвестным классом", showUnknownTip = "Недоступные сведения о классе не означают, что игрок безопасен.",
    displayClasses = "Классы в списке", alertClasses = "Классы для обычных оповещений",
    classesTip = "Фильтр классов относится к обычным встречам. Личные списки и важные события настраиваются отдельно.",
    watch = "Следить", avoid = "Опасный", ignore = "Игнорировать", removeList = "Убрать из списка", note = "Личная заметка", saveNote = "Сохранить",
    details = "Сведения об игроке", selectContact = "Выберите игрока в списке рядом или в журнале.",
    identityUnknown = "Для личного списка нужен доступный идентификатор. Анонимную встречу сохранить нельзя.",
    noTarget = "Нажатие открывает сведения и не меняет вашу цель.",
    reason = "Основание", source = "Источники", observed = "Замечен вашим клиентом", notSeen = "Больше не виден",
    selectedProfile = "Активный профиль", preset = "Готовая настройка", balanced = "Обычный", farming = "Фарм", quiet = "Тихий", battleground = "Поле боя",
    balancedTip = "Все классы, полезные оповещения и ограничение повторов.", farmingTip = "Обычные оповещения о разбойниках, охотниках и друидах.",
    quietTip = "Визуальные подсказки без звука.", battlegroundTip = "Меньше обычных оповещений на многолюдном поле боя.",
    presetHelp = "Создайте профиль из готовой настройки. Ваш существующий профиль сохранится.",
    createProfile = "Создать профиль", profileName = "Имя нового профиля", useProfile = "Выбрать", deleteProfile = "Удалить", noProfiles = "Нет доступных профилей",
    profileDeleted = "Профиль удалён.", profileCreated = "Профиль создан.", profileUsed = "Профиль выбран.",
    profileError = "Не удалось изменить профиль. Укажите допустимое уникальное имя.",
    deleteConfirm = "Нажмите «Удалить» ещё раз для подтверждения.",
    alertsEnabled = "Включить оповещения", sound = "Звук оповещений", banner = "Показывать предупреждение", soundChannel = "Канал звука",
    soundChannelTip = "Основной канал слышен при пониженной громкости отдельных каналов; общее отключение звука игры действует всегда.",
    master = "Основной", sfx = "Эффекты", music = "Музыка", ambience = "Окружение", dialog = "Диалоги",
    alertStealth = "Замеченная скрытность", alertStealthTip = "Предупреждать при доступном событии скрытности. Одно исчезновение неймплейта её не доказывает.",
    alertTargeting = "Противник выбрал вас целью", alertTargetingTip = "Предупреждать, когда доступная цель противника совпадает с вами. Это ещё не доказывает нападение.",
    watchedOnly = "Оповещать только о личных списках", watchedOnlyTip = "Обычные оповещения только об игроках в списках наблюдения и опасных.",
    muteOrdinary = "Без обычных оповещений", muteOrdinaryTip = "Личные списки и важные события остаются доступны.",
    cooldown = "Пауза между повторами", cooldownTip = "Секунд до следующего обычного оповещения об одном игроке.",
    returnAfter = "Новая встреча через", returnAfterTip = "Сколько игрок должен отсутствовать, чтобы следующая встреча снова вызвала оповещение.",
    rangeFilter = "Ограничить обычные оповещения расстоянием", rangeFilterTip = "Расстояние бывает приблизительным или недоступным. Дальность обнаружения не увеличивается.",
    rangeYards = "Порог расстояния (ярды)", rangePolicy = "Если диапазон пересекает порог", possible = "Если может быть близко", confirmed = "Только точно близко",
    unknownRange = "Оповещать при неизвестном расстоянии", contexts = "Где работает RivalGuard", world = "Открытый мир", arena = "Арена", instance = "Подземелья и рейды",
    sanctuary = "Святилища", resting = "Зоны отдыха", flight = "Во время перелёта",
    showBadges = "Значки классов на неймплейтах", showBadgesTip = "Отмечать доступные неймплейты противников, не изменяя стандартные полосы здоровья и выбор цели.",
    locked = "Закрепить список", highContrast = "Высокая контрастность", reducedMotion = "Меньше анимации", streamer = "Скрывать имена в RivalGuard",
    streamerTip = "Временные псевдонимы в RivalGuard. Интерфейс игры, чат и другие аддоны не изменяются.",
    textSize = "Размер текста списка", scale = "Масштаб списка", maxRows = "Видимых строк", resetPosition = "Сбросить положение окон",
    previewBanner = "Пример оповещения", previewList = "Пример списка", appearanceHelp = "Изменения применяются сразу. Незакреплённый список и пример оповещения можно перетаскивать.",
    nearbyTitle = "Противники рядом", alertTitle = "Замечен противник", watchTitle = "Игрок из списка", stealthTitle = "Замечена скрытность",
    targetingTitle = "Противник выбрал вас целью", waveTitle = "Замечено несколько противников", waveBody = "Почти одновременно замечено: %d",
    demoLabel = "Пример", demoRogue = "Пример: разбойник", demoHunter = "Пример: охотник", demoMage = "Пример: маг", demoWatch = "Пример: соперник",
    badgeTip = "Значок класса RivalGuard", status = "Состояние обнаружения", sensorLimited = "Часть сведений недоступна",
    statusHelp = "RivalGuard не видит полностью скрытых игроков. Отсутствие встреч не означает, что место безопасно.",
    supportHelp = "Если что-то работает странно, скопируйте диагностический отчёт. Он создаётся локально и никуда не отправляется автоматически.",
    diagnostics = "Скопировать диагностику", copyTitle = "Диагностический отчёт", copyHelp = "Выделите текст и нажмите Ctrl+C. Затем закройте окно.",
    reportUnavailable = "Диагностика пока недоступна.", records = "Недавние записи", emptyJournal = "Сохранённых встреч пока нет",
    journalHelp = "Недавние встречи и личные списки. Выберите запись, чтобы открыть сведения.",
    noJournalAPI = "Журнал встреч недоступен в этой сборке.", noProfileAPI = "Управление профилями недоступно в этой сборке.",
    noListAPI = "Редактирование личных списков недоступно в этой сборке.", nothingSelected = "Игрок не выбран",
    saved = "Сохранено.", saveFailed = "Не удалось сохранить запись.", settingsHint = "Полезные настройки уже включены. Меняйте только то, что нужно вам.",
    classSelection = "Выбрано: %d", language = "Язык", automatic = "Автоматически", english = "English", russian = "Русский",
    languageTip = "Язык RivalGuard. Язык игры и других аддонов не изменяется.",
    sensorReady = "Обнаружение работает", sensorUnavailable = "Обнаружение недоступно", noData = "Нет доступных данных",
    nameplatesOff = "Неймплейты противников выключены. Включите их в настройках игры, чтобы замечать больше игроков.",
    settingUnavailable = "Недоступно на этом клиенте", error = "Не удалось выполнить действие.",
}

function L.Get(key, requested)
    local locale = requested
    if locale == nil or locale == "auto" then locale = GetLocale and GetLocale() or "enUS" end
    local strings = locale == "ruRU" and L.ruRU or L.enUS
    return strings[key] or L.enUS[key] or key
end

function L.Format(key, locale, ...)
    return string.format(L.Get(key, locale), ...)
end

local CLASS_NAMES = {
    enUS = { WARRIOR = "Warrior", PALADIN = "Paladin", HUNTER = "Hunter", ROGUE = "Rogue", PRIEST = "Priest", DEATHKNIGHT = "Death Knight", SHAMAN = "Shaman", MAGE = "Mage", WARLOCK = "Warlock", MONK = "Monk", DRUID = "Druid", DEMONHUNTER = "Demon Hunter", EVOKER = "Evoker" },
    ruRU = { WARRIOR = "Воин", PALADIN = "Паладин", HUNTER = "Охотник", ROGUE = "Разбойник", PRIEST = "Жрец", DEATHKNIGHT = "Рыцарь смерти", SHAMAN = "Шаман", MAGE = "Маг", WARLOCK = "Чернокнижник", MONK = "Монах", DRUID = "Друид", DEMONHUNTER = "Охотник на демонов", EVOKER = "Пробудитель" },
}

function L.Class(token, requested)
    local locale = requested
    if locale == nil or locale == "auto" then
        locale = GetLocale and GetLocale() or "enUS"
        if locale ~= "ruRU" and LOCALIZED_CLASS_NAMES_MALE and LOCALIZED_CLASS_NAMES_MALE[token] then
            return LOCALIZED_CLASS_NAMES_MALE[token]
        end
    end
    return (CLASS_NAMES[locale] or CLASS_NAMES.enUS)[token] or L.Get("unknownClass", requested)
end
