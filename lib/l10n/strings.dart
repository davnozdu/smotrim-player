import 'package:flutter/widgets.dart';

/// Lightweight localization (English / Russian / Ukrainian). Language follows
/// the system locale via [Localizations.localeOf].
class S {
  final String _lang;
  S(this._lang);

  static const supportedLocales = [Locale('en'), Locale('ru'), Locale('uk')];

  static S of(BuildContext context) {
    final code = Localizations.localeOf(context).languageCode;
    return S(code == 'ru' || code == 'uk' ? code : 'en');
  }

  String _t(String en, String ru, String uk) {
    switch (_lang) {
      case 'ru':
        return ru;
      case 'uk':
        return uk;
      default:
        return en;
    }
  }

  // Menu
  String get channels => _t('Channels', 'Каналы', 'Канали');
  String get guide => _t('Guide', 'Программа', 'Програма');
  String get favorites => _t('Favorites', 'Избранное', 'Вибране');
  String get history => _t('History', 'История', 'Історія');
  String get settings => _t('Settings', 'Настройки', 'Налаштування');
  String get all => _t('All', 'Все', 'Усі');

  // Channels / search
  String get search => _t('Search…', 'Поиск…', 'Пошук…');
  String get searchChannels =>
      _t('Search channels…', 'Поиск каналов…', 'Пошук каналів…');

  // Guide
  String get noGuideData =>
      _t('No guide data', 'Нет данных программы', 'Немає даних програми');
  String get other => _t('Other', 'Другое', 'Інше');

  // Player / archive
  String get live => _t('Live', 'Эфир', 'Ефір');
  String get loadingArchive =>
      _t('Loading archive…', 'Загрузка архива…', 'Завантаження архіву…');
  String get noArchive => _t(
    'No archive programmes for this channel',
    'Нет архивных передач для этого канала',
    'Немає архівних передач для цього каналу',
  );
  String get selectAudio => _t('Select audio', 'Выбор аудио', 'Вибір аудіо');
  String programLeft(int min) => _t(
    '$min min left',
    'осталось $min мин',
    'залишилось $min хв',
  );

  // Channel context menu
  String get play => _t('Play', 'Смотреть', 'Дивитися');
  String get addToFavorites =>
      _t('Add to Favorites', 'Добавить в избранное', 'Додати у вибране');
  String get removeFromFavorites => _t(
    'Remove from Favorites',
    'Убрать из избранного',
    'Прибрати з вибраного',
  );
  String get addedToFavorites =>
      _t('Added to favorites', 'Добавлено в избранное', 'Додано у вибране');
  String get removedFromFavorites => _t(
    'Removed from favorites',
    'Убрано из избранного',
    'Прибрано з вибраного',
  );

  // Settings
  String get checkUpdate => _t(
    'Check for updates',
    'Проверить обновления',
    'Перевірити оновлення',
  );
  String get upToDate => _t(
    'You have the latest version',
    'У вас последняя версия',
    'У вас остання версія',
  );
  String get checkFailed => _t(
    'Update check failed',
    'Не удалось проверить обновления',
    'Не вдалося перевірити оновлення',
  );
  String get defaultView =>
      _t('Default view', 'Вид по умолчанию', 'Вигляд за замовчуванням');
  String get forceTvMode => _t(
    'Force TV Mode',
    'Принудительный ТВ-режим',
    'Примусовий ТБ-режим',
  );
  String get lowLatency => _t(
    'Low latency livestreams',
    'Низкая задержка эфира',
    'Низька затримка ефіру',
  );
  String get lowLatencySub => _t(
    'Minimal delay, smaller buffer (may stutter on weak networks)',
    'Минимальная задержка, меньше буфер (возможны рывки на слабой сети)',
    'Мінімальна затримка, менший буфер (можливі ривки на слабкій мережі)',
  );
  String get bufferSize => _t('Buffer size', 'Размер буфера', 'Розмір буфера');
  String get auto => _t('Auto', 'Авто', 'Авто');
  String get bufferAutoSub => _t(
    'Auto — grows when the stream stalls',
    'Авто — растёт при подвисаниях',
    'Авто — зростає при підвисаннях',
  );
  String bufferSecondsSub(int s) => _t(
    '$s seconds — larger = more stable HD',
    '$s сек — больше = стабильнее HD',
    '$s сек — більше = стабільніше HD',
  );
  String get seconds => _t('seconds', 'сек', 'сек');
  String get extendedArchive => _t(
    'Extended archive (7 days)',
    'Расширенный архив (7 дней)',
    'Розширений архів (7 днів)',
  );
  String get extendedArchiveSub => _t(
    'More history via iptvx.one — slower first open (default: 1 day)',
    'Больше истории через iptvx.one — первое открытие дольше (по умолчанию 1 день)',
    'Більше історії через iptvx.one — перше відкриття довше (за замовчуванням 1 день)',
  );
  String get fillLogos =>
      _t('Fill logos from EPG', 'Логотипы из EPG', 'Логотипи з EPG');
  String get fillLogosSub => _t(
    'Use an EPG (XMLTV) source to fill missing channel logos',
    'Брать логотипы каналов из EPG (XMLTV)',
    'Брати логотипи каналів з EPG (XMLTV)',
  );
  String get epgUrl => _t('EPG URL', 'EPG URL', 'EPG URL');
  String get notSet => _t('Not set', 'Не задано', 'Не задано');
  String get refreshOnStart => _t(
    'Refresh sources on start',
    'Обновлять источники при запуске',
    'Оновлювати джерела під час запуску',
  );
  String get sources => _t('Sources', 'Источники', 'Джерела');
  String get addPlaylist =>
      _t('Add playlist', 'Добавить плейлист', 'Додати плейлист');
  String get addPlaylistSub => _t(
    'Run the wizard to add another playlist (the current one is kept)',
    'Запустить мастер и добавить ещё один плейлист (текущий сохранится)',
    'Запустити майстер і додати ще один плейлист (поточний збережеться)',
  );
  String playlistSwitched(String name) => _t(
    'Active playlist: $name',
    'Активен плейлист: $name',
    'Активний плейлист: $name',
  );
  String get switchPlaylistHint => _t(
    'Select the active playlist with the radio button on the left',
    'Выберите активный плейлист кружком слева',
    'Виберіть активний плейлист кружечком зліва',
  );
  String get makeActive =>
      _t('Make active', 'Сделать активным', 'Зробити активним');
  String get refreshAllSourcesTitle =>
      _t('Refresh all', 'Обновить все', 'Оновити всі');
  String get editSourceTooltip => _t('Edit', 'Изменить', 'Змінити');
  String get refreshSourceTooltip => _t('Refresh', 'Обновить', 'Оновити');
  String get deleteSourceTooltip => _t('Delete', 'Удалить', 'Видалити');

  // Common
  String get cancel => _t('Cancel', 'Отмена', 'Скасувати');
  String get save => _t('Save', 'Сохранить', 'Зберегти');
  String get next => _t('Next', 'Далее', 'Далі');
  String get back => _t('Back', 'Назад', 'Назад');
  String get close => _t('Close', 'Закрыть', 'Закрити');

  // Subscription / payment
  String get renewSubscription =>
      _t('Renew subscription', 'Продлить подписку', 'Продовжити підписку');
  String get subscriptionDialogTitle => _t(
    'Subscription renewal',
    'Продление подписки',
    'Продовження підписки',
  );
  String get subscriptionScanToPay => _t(
    'Scan the QR code to pay',
    'Отсканируйте QR-код для оплаты',
    'Відскануйте QR-код для оплати',
  );
  String get subscriptionAmountLabel => _t('Amount', 'Сумма', 'Сума');
  String get subscriptionAccountLabel =>
      _t('Account number', 'Номер счёта', 'Номер рахунку');
  String get subscriptionIbanLabel => _t('IBAN', 'IBAN', 'IBAN');
  String get subscriptionBicLabel => _t('BIC/SWIFT', 'BIC/SWIFT', 'BIC/SWIFT');
  String get subscriptionProcessingHours => _t(
    'Payments are processed during business hours; on weekends upon request.',
    'Платежи обрабатываются в рабочее время, в выходные — по запросу.',
    'Платежі обробляються в робочий час, у вихідні — за запитом.',
  );
  String get subscriptionContactLabel =>
      _t('Payment questions', 'Вопросы по оплате', 'Питання щодо оплати');
  String get payByTransfer =>
      _t('Bank transfer', 'Перевести на счёт', 'Переказати на рахунок');
  String get payByCard => _t('Pay by card', 'Оплатить картой', 'Сплатити карткою');
  String get subscriptionYourPhone =>
      _t('Your phone number', 'Ваш номер телефона', 'Ваш номер телефону');
  String get yourEmail => _t('Your email', 'Ваш email', 'Ваш email');
  String get subscriptionCardPhoneNote => _t(
    'When paying, include your phone number, your subscriber ID and email.',
    'При оплате укажите свой номер телефона, свой ID абонента и email.',
    'Під час оплати вкажіть свій номер телефону, ваш ID абонента та email.',
  );
  String get subscriptionCardCommission =>
      _t('Commission: 100 Kč', 'Комиссия: 100 Kč', 'Комісія: 100 Kč');
  String get becomeSubscriber =>
      _t('Become a subscriber', 'Стать абонентом', 'Стати абонентом');
  String get becomeNote => _t(
    "The price includes subscription activation and a one-year membership. "
        "Next year's renewal is 1000 CZK. After activation you will receive "
        "your login details.",
    'Стоимость включает активацию подписки и годовой абонемент. Следующий год '
        'продления — 1000 крон. После активации абонемента вы получите данные '
        'для входа.',
    'Вартість включає активацію підписки та річний абонемент. Наступний рік '
        'продовження — 1000 крон. Після активації абонемента ви отримаєте дані '
        'для входу.',
  );
  // Shown on the "become a subscriber" payment-method menu.
  String get becomeMenuNote => _t(
    'The activation starter kit includes a one-year membership. '
        "Next year's renewal is 1000 CZK. After activation you will receive a "
        'confirmation to your email. Choose a payment method.',
    'Стартовый комплект активации включает годовой абонемент. Следующий год '
        'продления — 1000 крон. После активации вы получите подтверждение на '
        'свой email. Выберите способ оплаты.',
    'Стартовий комплект активації включає річний абонемент. Наступний рік '
        'продовження — 1000 крон. Після активації ви отримаєте підтвердження '
        'на свій email. Виберіть спосіб оплати.',
  );
  String get yourPin => _t('Your PIN', 'Ваш PIN', 'Ваш PIN');
  String get becomeSaveCredentials => _t(
    'Save your ID and PIN — these are your login details.',
    'Сохраните ID и PIN — это ваши данные для входа.',
    'Збережіть ID та PIN — це ваші дані для входу.',
  );

  // Updates
  String updateAvailable(String version) => _t(
    'Update available ($version)',
    'Доступно обновление ($version)',
    'Доступне оновлення ($version)',
  );
  String get update => _t('Update', 'Обновить', 'Оновити');
  String get later => _t('Later', 'Позже', 'Пізніше');
  String get downloadingUpdate => _t(
    'Downloading update…',
    'Загрузка обновления…',
    'Завантаження оновлення…',
  );

  // Setup wizard
  String welcomeTitle(String app) =>
      _t('Welcome to $app', 'Добро пожаловать в $app', 'Ласкаво просимо до $app');
  String welcomeSub(bool first) => first
      ? _t(
          "Let's set up your first source",
          'Давайте настроим ваш первый источник',
          'Налаштуймо ваше перше джерело',
        )
      : _t(
          "Let's set up your new source",
          'Давайте настроим новый источник',
          'Налаштуймо нове джерело',
        );
  String get providerType => _t(
    'What is your provider type?',
    'Какой у вас тип провайдера?',
    'Який у вас тип провайдера?',
  );
  String get nameQuestion => _t(
    'What should we name this source?',
    'Как назвать этот источник?',
    'Як назвати це джерело?',
  );
  String get name => _t('Name', 'Название', 'Назва');
  String get urlQuestion => _t(
    "What is your provider's URL?",
    'Какой URL у провайдера?',
    'Який URL у провайдера?',
  );
  String get url => _t('URL', 'URL', 'URL');
  String get usernameQuestion =>
      _t('What is your username?', 'Ваш логин?', 'Ваш логін?');
  String get username => _t('Username', 'Логин', 'Логін');
  String get passwordQuestion =>
      _t('What is your password?', 'Ваш пароль?', 'Ваш пароль?');
  String get password => _t('Password', 'Пароль', 'Пароль');
  String get selectFile => _t('Select file', 'Выбрать файл', 'Вибрати файл');

  // HLS proxy source
  String get hlsProxyQuestion => _t(
    'Enter your HLS-PROXY details',
    'Введите данные HLS-PROXY',
    'Введіть дані HLS-PROXY',
  );
  String get hlsProxyIp => _t('IP address', 'IP-адрес', 'IP-адреса');
  String get hlsProxyPort => _t('Port', 'Порт', 'Порт');
  String get hlsProxyPlaylist => _t('Playlist', 'Плейлист', 'Плейлист');
  String get hlsProxyResult =>
      _t('Resulting link', 'Итоговая ссылка', 'Підсумкове посилання');
  String get proxyChecking =>
      _t('Checking server…', 'Проверка сервера…', 'Перевірка сервера…');
  String get proxyOnline => _t(
    'Server is running (port open)',
    'Сервер работает (порт открыт)',
    'Сервер працює (порт відкрито)',
  );
  String get proxyOffline => _t(
    'Service is not running or not installed',
    'Сервис не запущен или не установлен',
    'Сервіс не запущено або не встановлено',
  );
  String get proxyRecheck => _t('Recheck', 'Проверить', 'Перевірити');
  String get proxyInstall =>
      _t('Install HLS-PROXY?', 'Установить HLS-PROXY?', 'Встановити HLS-PROXY?');
  String get proxyUpdate => _t(
    'Update HLS-PROXY',
    'Обновить HLS-PROXY',
    'Оновити HLS-PROXY',
  );
  String get proxyAlreadyInstalled => _t(
    'HLS-PROXY is already installed. Update to the latest version?',
    'HLS-PROXY уже установлен. Обновить до последней версии?',
    'HLS-PROXY вже встановлено. Оновити до останньої версії?',
  );
  String get proxyAfterInstall => _t(
    'After installing, add your playlist and complete the setup.',
    'После установки добавьте свой плейлист и проведите настройку.',
    'Після встановлення додайте свій плейлист і проведіть налаштування.',
  );
  String get finish => _t('Finish', 'Готово', 'Готово');
  String get doneTitle => _t('Done!', 'Готово!', 'Готово!');
  String get doneSub =>
      _t("You're all set 🎉", 'Всё настроено 🎉', 'Усе налаштовано 🎉');
  String get nameExists =>
      _t('Name already exists', 'Название уже занято', 'Назва вже зайнята');

  // View types (default view dialog)
  String get categories => _t('Categories', 'Категории', 'Категорії');

  // Confirm delete
  String get confirmDeletion =>
      _t('Confirm deletion', 'Подтвердите удаление', 'Підтвердьте видалення');
  String get confirm => _t('Confirm', 'Подтвердить', 'Підтвердити');
  String deleteWhat(String type, String name) => _t(
    'You are about to delete $type "$name"',
    'Вы собираетесь удалить $type «$name»',
    'Ви збираєтеся видалити $type «$name»',
  );
  String get sourceType => _t('source', 'источник', 'джерело');

  // Edit source
  String editSource(String name) =>
      _t('Edit source $name', 'Изменить источник $name', 'Змінити джерело $name');

  // Validators / misc
  String get settingsDisabledRefreshing => _t(
    'Settings disabled while refreshing on start',
    'Настройки недоступны во время обновления при запуске',
    'Налаштування недоступні під час оновлення під час запуску',
  );
  String get scrollToTop => _t('Scroll to Top', 'Наверх', 'Догори');
  String get pressAgainToExit => _t(
    'Press back again to exit',
    'Нажмите ещё раз, чтобы выйти',
    'Натисніть ще раз, щоб вийти',
  );

  // Success snackbars
  String get sourceRefreshed => _t(
    'Source has been refreshed successfully',
    'Источник успешно обновлён',
    'Джерело успішно оновлено',
  );
  String get sourcesRefreshed => _t(
    'Successfully refreshed all sources',
    'Все источники успешно обновлены',
    'Усі джерела успішно оновлено',
  );
  String get sourceDeleted => _t(
    'Successfully deleted source',
    'Источник успешно удалён',
    'Джерело успішно видалено',
  );
  String sourceToggled(bool enabled) => enabled
      ? _t('Source enabled', 'Источник включён', 'Джерело увімкнено')
      : _t('Source disabled', 'Источник выключен', 'Джерело вимкнено');

  // Correction modal
  String get correctUrlTitle => _t(
    'Is this the right URL?',
    'Это правильный URL?',
    'Це правильний URL?',
  );
  String get proceedAnyway =>
      _t('Proceed anyway', 'Всё равно продолжить', 'Усе одно продовжити');
  String get correctUrlAuto => _t(
    'Correct URL automatically',
    'Исправить URL автоматически',
    'Виправити URL автоматично',
  );
  String get correctUrlBody => _t(
    'It seems your URL is not pointing to an Xtream API server. The URL can be corrected automatically.',
    'Похоже, ваш URL не указывает на Xtream API сервер. URL можно исправить автоматически.',
    'Схоже, ваш URL не вказує на Xtream API сервер. URL можна виправити автоматично.',
  );

  // Error dialog
  String get errorTitle => _t(
    "An error occurred. Tap 'Details' for more information",
    'Произошла ошибка. Нажмите «Детали» для подробностей',
    'Сталася помилка. Натисніть «Деталі» для подробиць',
  );
  String get errorDetailsBody => _t(
    'The following error occurred. If it persists, please report it.\n',
    'Произошла следующая ошибка. Если она повторяется, сообщите о ней.\n',
    'Сталася наступна помилка. Якщо вона повторюється, повідомте про неї.\n',
  );
  String get reportIssue =>
      _t('Report issue', 'Сообщить о проблеме', 'Повідомити про проблему');
  String get details => _t('Details', 'Детали', 'Деталі');
  String get actionCompleted => _t(
    'Action completed successfully',
    'Действие выполнено успешно',
    'Дію виконано успішно',
  );

  // Common
  String get ok => _t('OK', 'OK', 'OK');

  // Hide categories / parental control
  String get hideCategories =>
      _t('Hide categories', 'Скрыть категории', 'Сховати категорії');
  String get hideCategoriesSub => _t(
    'Hide categories you do not watch and set parental PINs',
    'Скрыть ненужные категории и поставить родительский пароль',
    'Сховати непотрібні категорії та поставити батьківський пароль',
  );
  String get noCategories => _t(
    'No categories found',
    'Категории не найдены',
    'Категорії не знайдено',
  );
  String get setPin =>
      _t('Set PIN', 'Установить пин-код', 'Встановити пін-код');
  String get resetPin =>
      _t('Reset PIN', 'Сбросить пин-код', 'Скинути пін-код');
  String get enterPin =>
      _t('Enter 4-digit PIN', 'Введите 4 цифры пин-кода', 'Введіть 4 цифри пін-коду');
  String get repeatPin =>
      _t('Repeat PIN', 'Повторите пин-код', 'Повторіть пін-код');
  String get enterCurrentPin => _t(
    'Enter current PIN',
    'Введите текущий пин-код',
    'Введіть поточний пін-код',
  );
  String get pinMismatch =>
      _t('PINs do not match', 'Пин-коды не совпадают', 'Пін-коди не збігаються');
  String get pinInvalid => _t(
    'PIN must be 4 digits',
    'Пин-код должен состоять из 4 цифр',
    'Пін-код має складатися з 4 цифр',
  );
  String get pinWrong => _t('Wrong PIN', 'Неверный пин-код', 'Невірний пін-код');
  String get pinSet =>
      _t('PIN set', 'Пин-код установлен', 'Пін-код встановлено');
  String get pinRemoved =>
      _t('PIN removed', 'Пин-код снят', 'Пін-код знято');
  String get enterPinToOpen => _t(
    'Enter PIN to open this category',
    'Введите пин-код, чтобы открыть категорию',
    'Введіть пін-код, щоб відкрити категорію',
  );
  String get locked => _t('Locked', 'Заблокировано', 'Заблоковано');
  String get categoryHidden => _t('Hidden', 'Скрыта', 'Прихована');
  String get categoryShown => _t('Shown', 'Показывается', 'Показується');

  // Inactivity / "still watching?"
  String get inactivityTimeout => _t(
    '"Still watching?" on inactivity',
    '«Вы ещё смотрите?» при бездействии',
    '«Ви ще дивитесь?» при бездіяльності',
  );
  String inactivityTimeoutSub(String value) => _t(
    'Ask after $value of no activity',
    'Спрашивать после $value без действий',
    'Питати після $value без дій',
  );
  String get never => _t('Never', 'Никогда', 'Ніколи');
  String hoursLabel(double h) {
    final isInt = h == h.roundToDouble();
    final v = isInt ? h.toInt().toString() : h.toString();
    return _t('$v h', '$v ч', '$v год');
  }
  String minutesLabel(int m) => _t('$m min', '$m мин', '$m хв');
  String get yes => _t('Yes', 'Да', 'Так');
  String get stillWatchingTitle =>
      _t('Still watching?', 'Вы ещё смотрите?', 'Ви ще дивитесь?');
  String stillWatchingBody(int sec) => _t(
    'Playback will pause in $sec s',
    'Воспроизведение остановится через $sec с',
    'Відтворення зупиниться через $sec с',
  );

  // Resume playback
  String get resumePlayback => _t(
    'Resume playback',
    'Продолжать воспроизведение',
    'Продовжувати відтворення',
  );
  String get resumePlaybackSub => _t(
    'If the box is turned off on a channel, continue it on next start',
    'Если приставку выключили на канале — продолжить его при запуске',
    'Якщо приставку вимкнули на каналі — продовжити його під час запуску',
  );

  // Autostart
  String get autostartOnBoot => _t(
    'Autostart on device boot',
    'Автозапуск при загрузке устройства',
    'Автозапуск при завантаженні пристрою',
  );
  String get autostartOnBootSub => _t(
    'Open the app automatically after the box powers on',
    'Открывать приложение автоматически после включения приставки',
    'Відкривати застосунок автоматично після ввімкнення приставки',
  );
  String get autostartAction =>
      _t('What to open on autostart', 'Что открывать при автозапуске',
          'Що відкривати при автозапуску');
  String get overlayNeededTitle => _t(
    'Permission required',
    'Нужно разрешение',
    'Потрібен дозвіл',
  );
  String get overlayNeededBody => _t(
    'For autostart to work, Android requires the "Display over other apps" '
        'permission. Open settings and enable it for Smotrim CZ Player.',
    'Чтобы автозапуск работал, Android требует разрешение «Поверх других '
        'приложений». Откройте настройки и включите его для Smotrim CZ Player.',
    'Щоб автозапуск працював, Android вимагає дозвіл «Поверх інших застосунків». '
        'Відкрийте налаштування та увімкніть його для Smotrim CZ Player.',
  );
  String get openSettings =>
      _t('Open settings', 'Открыть настройки', 'Відкрити налаштування');
  String get waitingForNetwork => _t(
    'Waiting for the network and required components…',
    'Ожидаем запуск сети и необходимых компонентов…',
    'Очікуємо запуск мережі та необхідних компонентів…',
  );
  String get autostartMenu => _t('Menu', 'Меню', 'Меню');
  String get autostartLast =>
      _t('Last channel', 'Последний канал', 'Останній канал');
  String get autostartCategory => _t(
    'Channel from a category',
    'Канал из категории',
    'Канал з категорії',
  );
  String get autostartChannel =>
      _t('Specific channel', 'Свой канал', 'Власний канал');
  String get selectCategory =>
      _t('Select category', 'Выберите категорию', 'Виберіть категорію');
  String get selectChannel =>
      _t('Select channel', 'Выберите канал', 'Виберіть канал');
  String get notChosen => _t('Not chosen', 'Не выбрано', 'Не вибрано');

  // Hotel / kiosk mode
  String get hotelMode => _t('Hotel mode', 'Режим отеля', 'Режим готелю');
  String get hotelModeSub => _t(
    'View only: channels, guide, favorites and history. Hides settings.',
    'Только просмотр: каналы, программа, избранное и история. Настройки скрыты.',
    'Лише перегляд: канали, програма, вибране та історія. Налаштування приховані.',
  );
  String get hotelEnterNewPin => _t(
    'Create an 8-digit PIN',
    'Придумайте пин-код (8 цифр)',
    'Придумайте пін-код (8 цифр)',
  );
  String get hotelRepeatPin => _t(
    'Repeat the PIN',
    'Повторите пин-код',
    'Повторіть пін-код',
  );
  String get hotelEnterPin =>
      _t('Enter the PIN', 'Введите пин-код', 'Введіть пін-код');
  String get hotelPin8Hint => _t(
    'The PIN protects exiting hotel mode',
    'Пин-код защищает выход из режима отеля',
    'Пін-код захищає вихід з режиму готелю',
  );
  String get hotelEnabled =>
      _t('Hotel mode enabled', 'Режим отеля включён', 'Режим готелю увімкнено');
  String get hotelManageTitle =>
      _t('Hotel mode', 'Режим отеля', 'Режим готелю');
  String get hotelDisable => _t(
    'Disable hotel mode',
    'Отключить режим отеля',
    'Вимкнути режим готелю',
  );
  String get hotelExit => _t(
    'Exit hotel mode',
    'Выйти из режима отеля',
    'Вийти з режиму готелю',
  );
  String get hotelResetGuest => _t(
    'Reset guest data',
    'Сбросить данные гостя',
    'Скинути дані гостя',
  );
  String get hotelGuestReset => _t(
    'Guest data has been reset',
    'Данные гостя сброшены',
    'Дані гостя скинуто',
  );
  String get clearFavorites =>
      _t('Clear favorites', 'Очистить избранное', 'Очистити вибране');
  String get clearFavoritesConfirm => _t(
    'Remove all channels from favorites?',
    'Убрать все каналы из избранного?',
    'Прибрати всі канали з вибраного?',
  );
  String get favoritesCleared =>
      _t('Favorites cleared', 'Избранное очищено', 'Вибране очищено');

  // Subscriber identity (ID + PIN) and playlist restore
  String get yourId => _t('Your ID', 'Ваш ID', 'Ваш ID');
  String get hideId => _t('Hide ID', 'Скрыть ID', 'Сховати ID');
  String get hideIdSub => _t(
    'Hide the subscriber ID in the corner of the home screen',
    'Скрыть ID абонента в углу главного экрана',
    'Сховати ID абонента в кутку головного екрана',
  );
  String get showPinCode =>
      _t('Show PIN code', 'Показать пин-код', 'Показати пін-код');
  String get subscriberPinTitle =>
      _t('Your PIN code', 'Ваш пин-код', 'Ваш пін-код');
  String get credentialsTitle =>
      _t('Your ID and PIN', 'Ваш ID и пин-код', 'Ваш ID та пін-код');
  String credentialsBody(String id, String pin) => _t(
    'Your ID: $id\nYour PIN: $pin\n\nSave this in a safe place. '
        'It identifies you as a subscriber.',
    'Ваш ID: $id\nВаш пин-код: $pin\n\nСохраните эти данные в надёжном месте. '
        'Они служат для вашей идентификации как абонента.',
    'Ваш ID: $id\nВаш пін-код: $pin\n\nЗбережіть ці дані в надійному місці. '
        'Вони служать для вашої ідентифікації як абонента.',
  );
  String get restorePlaylist =>
      _t('Restore playlist', 'Восстановить плейлист', 'Відновити плейлист');
  String get restorePlaylistSub => _t(
    'Download your playlist by ID and PIN',
    'Скачать ваш плейлист по ID и пин-коду',
    'Завантажити ваш плейлист за ID та пін-кодом',
  );
  String get restoreIdLabel => _t('ID (8 digits)', 'ID (8 цифр)', 'ID (8 цифр)');
  String get restorePinLabel =>
      _t('PIN (6 digits)', 'Пин-код (6 цифр)', 'Пін-код (6 цифр)');
  String get send => _t('Send', 'Отправить', 'Надіслати');
  String get restoreInProgress => _t(
    'Restoring playlist…',
    'Восстановление плейлиста…',
    'Відновлення плейлиста…',
  );
  String get restoreSuccess => _t(
    'Playlist restored',
    'Плейлист восстановлен',
    'Плейлист відновлено',
  );
  String get restoreInvalidInput => _t(
    'Enter an 8-digit ID and a 6-digit PIN',
    'Введите 8-значный ID и 6-значный пин-код',
    'Введіть 8-значний ID та 6-значний пін-код',
  );
  String get restoreErrBadCredentials => _t(
    'Wrong ID or PIN',
    'Неверный ID или пин-код',
    'Невірний ID або пін-код',
  );
  String get restoreErrThrottled => _t(
    'Too many attempts. Try again later',
    'Слишком много попыток. Попробуйте позже',
    'Забагато спроб. Спробуйте пізніше',
  );
  String get restoreErrServer => _t(
    'Server is unavailable. Try again later',
    'Сервер недоступен. Попробуйте позже',
    'Сервер недоступний. Спробуйте пізніше',
  );
  String get restoreErrNetwork => _t(
    'No connection to the server',
    'Нет связи с сервером',
    'Немає зв’язку із сервером',
  );
  String get restoreErrBadPlaylist => _t(
    'The server returned an invalid playlist',
    'Сервер вернул некорректный плейлист',
    'Сервер повернув некоректний плейлист',
  );
  String get loginTitle => _t('Log in', 'Вход', 'Вхід');
  String get loginSub => _t(
    'Enter your ID and PIN to restore your playlist',
    'Введите ваш ID и пин-код, чтобы восстановить плейлист',
    'Введіть ваш ID та пін-код, щоб відновити плейлист',
  );
  String get loginButton => _t('Log in', 'Войти', 'Увійти');
  String get skipLogin =>
      _t('Skip login', 'Пропустить вход', 'Пропустити вхід');
}
