import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/api/failures/app_failure.dart';
import '../../../core/design_system/design_system.dart';
import '../../../core/device/device_info_source.dart';
import '../../../core/forms/validators.dart';
import '../../../core/pickers/country_names.dart';
import '../../../core/pickers/pickers.dart';
import '../../../l10n/gen/app_localizations.dart';
import '../../auth/application/me_controller.dart';
import '../../auth/data/auth_repository.dart';
import '../../auth/data/models/account_models.dart';
import 'settings_widgets.dart';

/// Settings > Profile: name, phone, country, timezone and language.
class ProfileScreen extends ConsumerWidget {
  const ProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context);
    final me = ref.watch(meControllerProvider);
    return me.when(
      data: (account) => account == null
          ? FormPage(
              title: l10n.settingsProfile,
              children: const [LoadingView()],
            )
          : _ProfileForm(account: account),
      loading: () => FormPage(
        title: l10n.settingsProfile,
        children: const [LoadingView()],
      ),
      error: (error, _) => FormPage(
        title: l10n.settingsProfile,
        children: [
          ErrorView(
            failure: error is AppFailure ? error : UnknownFailure(cause: error),
            onRetry: () => ref.read(meControllerProvider.notifier).refresh(),
          ),
        ],
      ),
    );
  }
}

class _ProfileForm extends ConsumerStatefulWidget {
  const _ProfileForm({required this.account});

  final MeResponse account;

  @override
  ConsumerState<_ProfileForm> createState() => _ProfileFormState();
}

class _ProfileFormState extends ConsumerState<_ProfileForm> {
  late final TextEditingController _name = TextEditingController(
    text: widget.account.profile.displayName,
  );
  late final TextEditingController _phone = TextEditingController(
    text: widget.account.profile.phoneE164 ?? '',
  );
  late String? _country = widget.account.profile.countryCode;
  late String _timezone = widget.account.profile.timezone;
  String? _deviceTimezone;
  bool _busy = false;
  AppFailure? _failure;
  FieldIssue? _nameIssue;
  FieldIssue? _phoneIssue;

  Profile get _saved => widget.account.profile;

  @override
  void initState() {
    super.initState();
    _readDeviceTimezone();
  }

  Future<void> _readDeviceTimezone() async {
    final tz = await ref.read(deviceInfoSourceProvider).timezone();
    if (mounted && tz != null) {
      setState(() => _deviceTimezone = tz);
    }
  }

  @override
  void dispose() {
    _name.dispose();
    _phone.dispose();
    super.dispose();
  }

  ProfilePatch _patch() {
    final name = _name.text.trim();
    final phone = _phone.text.trim();
    final hadPhone = (_saved.phoneE164 ?? '').isNotEmpty;
    return ProfilePatch(
      displayName: name != _saved.displayName ? name : null,
      phoneE164: phone.isNotEmpty && phone != (_saved.phoneE164 ?? '')
          ? phone
          : null,
      clearPhone: phone.isEmpty && hadPhone,
      countryCode: _country != null && _country != _saved.countryCode
          ? _country
          : null,
      clearCountry: _country == null && _saved.countryCode != null,
      timezone: _timezone != _saved.timezone ? _timezone : null,
    );
  }

  bool get _dirty => !_patch().isEmpty;

  Future<void> _save() async {
    final nameIssue = Validators.displayName(_name.text);
    final phoneIssue = Validators.phone(_phone.text);
    setState(() {
      _nameIssue = nameIssue;
      _phoneIssue = phoneIssue;
      _failure = null;
    });
    if (nameIssue != null || phoneIssue != null) {
      return;
    }
    final patch = _patch();
    if (patch.isEmpty) {
      return;
    }
    FocusScope.of(context).unfocus();
    setState(() => _busy = true);
    try {
      await ref.read(meControllerProvider.notifier).patchProfile(patch);
      if (!mounted) {
        return;
      }
      setState(() => _busy = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(AppLocalizations.of(context).profileSaved)),
      );
    } on AppFailure catch (failure) {
      if (mounted) {
        setState(() {
          _busy = false;
          _failure = failure;
        });
      }
    }
  }

  Future<void> _pickTimezone() async {
    final available = await ref
        .read(deviceInfoSourceProvider)
        .availableTimezones();
    if (!mounted) {
      return;
    }
    final chosen = await pickTimezone(
      context,
      available: available,
      selected: _timezone,
    );
    if (chosen != null && mounted) {
      setState(() => _timezone = chosen);
    }
  }

  Future<void> _pickCountry() async {
    final chosen = await pickCountry(context, selected: _country);
    if (chosen != null && mounted) {
      setState(() => _country = chosen == noCountry ? null : chosen);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context);
    final failure = _failure;
    FieldIssue? server(String field) => failure is ValidationFailure
        ? issueForField(failure.fieldErrors, field)
        : null;
    final serverName = server('display_name');
    final serverPhone = server('phone_e164');
    final handled = serverName != null || serverPhone != null;
    final mismatch =
        _deviceTimezone != null &&
        _deviceTimezone != _timezone &&
        _deviceTimezone != _saved.timezone;
    final device = _deviceTimezone;
    final country = countryName(_country);

    String? err(FieldIssue? local, FieldIssue? remote) {
      final issue = local ?? remote;
      return issue == null ? null : issueMessage(l10n, issue);
    }

    return FormPage(
      title: l10n.settingsProfile,
      children: [
        if (failure != null && !handled) ...[
          FailureNotice.of(context, failure),
          Gap.md,
        ],
        AppTextField(
          label: l10n.fieldName,
          controller: _name,
          errorText: err(_nameIssue, serverName),
          textInputAction: TextInputAction.next,
          textCapitalization: TextCapitalization.words,
          enabled: !_busy,
          onChanged: (_) => setState(() => _nameIssue = null),
        ),
        Gap.md,
        AppTextField(
          label: l10n.fieldPhone,
          hint: l10n.fieldPhoneHint,
          controller: _phone,
          errorText: err(_phoneIssue, serverPhone),
          keyboardType: TextInputType.phone,
          textInputAction: TextInputAction.done,
          autofillHints: const [AutofillHints.telephoneNumber],
          enabled: !_busy,
          onChanged: (_) => setState(() => _phoneIssue = null),
        ),
        Gap.xs,
        _ValueRow(
          label: l10n.fieldCountry,
          value: country ?? l10n.valueNotSet,
          onTap: _busy ? null : _pickCountry,
        ),
        _ValueRow(
          label: l10n.fieldTimezone,
          value: _timezone,
          onTap: _busy ? null : _pickTimezone,
        ),
        _ValueRow(label: l10n.fieldLanguage, value: l10n.languageEnglish),
        if (mismatch && device != null) ...[
          Gap.sm,
          StatusBanner(
            kind: StatusBannerKind.info,
            message: l10n.timezoneMismatch,
            action: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                FitText(device, style: Theme.of(context).textTheme.titleSmall),
                AppButton.text(
                  label: l10n.timezoneUseDevice,
                  onPressed: _busy
                      ? null
                      : () => setState(() => _timezone = device),
                ),
              ],
            ),
          ),
        ],
        Gap.lg,
        AppButton.primary(
          label: l10n.actionSave,
          isLoading: _busy,
          onPressed: _dirty ? _save : null,
          expand: true,
        ),
      ],
    );
  }
}

class _ValueRow extends StatelessWidget {
  const _ValueRow({required this.label, required this.value, this.onTap});

  final String label;
  final String value;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) =>
      SettingsTile(title: label, subtitle: value, onTap: onTap);
}
