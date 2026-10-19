import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../l10n/strings.dart';
import '../state/app_state.dart';
import '../theme/app_theme.dart';
import '../widgets/brand.dart';
import '../widgets/hero_network.dart';
import '../widgets/kit.dart';

class LandingScreen extends StatefulWidget {
  const LandingScreen({super.key});
  @override
  State<LandingScreen> createState() => _LandingScreenState();
}

class _LandingScreenState extends State<LandingScreen> {
  final _authKey = GlobalKey();

  void _toAuth() => Scrollable.ensureVisible(_authKey.currentContext!, duration: const Duration(milliseconds: 500), curve: Curves.easeOutCubic);

  @override
  Widget build(BuildContext context) {
    final k = context.k;
    final size = MediaQuery.sizeOf(context);
    final wide = size.width >= 1000;
    final heroH = wide ? size.height.clamp(640.0, 980.0) : size.height * 0.62;

    final headline = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Row(mainAxisSize: MainAxisSize.min, children: [
        Container(width: 6, height: 6, decoration: BoxDecoration(color: k.critical, shape: BoxShape.circle)),
        const SizedBox(width: 8),
        Flexible(child: Eyebrow(context.t('liveSim'), color: k.muted)),
      ]),
      const SizedBox(height: 18),
      Text(context.t('heroTitle'), style: KType.display(k.text, wide ? 84 : 48)),
      const SizedBox(height: 18),
      ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Text(context.t('heroBody'), style: TextStyle(fontSize: wide ? 17 : 15, height: 1.5, color: k.muted)),
      ),
      const SizedBox(height: 26),
      if (!wide) FilledButton(onPressed: _toAuth, child: Text(context.t('getStarted'))),
    ]);

    return Scaffold(
      body: SingleChildScrollView(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          SizedBox(
            height: heroH,
            child: Stack(children: [
              const Positioned.fill(child: HeroNetwork()),
              // legibility wash behind the text, not over the network
              Positioned.fill(child: IgnorePointer(child: DecoratedBox(decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: wide ? Alignment.centerLeft : Alignment.bottomCenter,
                  end: wide ? Alignment.centerRight : Alignment.topCenter,
                  colors: [k.bg, k.bg.withValues(alpha: 0.75), k.bg.withValues(alpha: 0.0)],
                  stops: wide ? const [0.0, 0.32, 0.62] : const [0.0, 0.35, 0.8],
                ),
              )))),
              Positioned(
                left: 0, right: 0, top: 0,
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
                  child: Row(children: [
                    const Wordmark(),
                    const Spacer(),
                    const LanguageMenu(),
                    if (!wide) ...[const SizedBox(width: 10), TextButton(onPressed: _toAuth, child: Text(context.t('signIn')))],
                  ]),
                ),
              ),
              Positioned(
                left: 28, bottom: wide ? 72 : 28, right: wide ? null : 28,
                child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 720), child: IgnorePointer(ignoring: wide, child: headline)),
              ),
              if (wide)
                Positioned(right: 48, top: 0, bottom: 0, child: Center(child: SizedBox(width: 400, child: AuthCard(key: _authKey)))),
            ]),
          ),
          if (!wide) Padding(padding: const EdgeInsets.all(20), child: AuthCard(key: _authKey)),
          _Points(wide: wide),
          Padding(
            padding: const EdgeInsets.fromLTRB(28, 8, 28, 36),
            child: Text(context.t('dataNote'), style: context.tt.bodySmall),
          ),
        ]),
      ),
    );
  }
}

class _Points extends StatelessWidget {
  final bool wide;
  const _Points({required this.wide});
  @override
  Widget build(BuildContext context) {
    final k = context.k;
    final stats = [('1,500', 'statCompanies'), ('8,090', 'statLinks'), ('16', 'statSectors'), ('23', 'statLanguages')];
    final points = [('01', 'point1Title', 'point1Body'), ('02', 'point2Title', 'point2Body'), ('03', 'point3Title', 'point3Body')];
    return Container(
      decoration: BoxDecoration(border: Border(top: BorderSide(color: k.line), bottom: BorderSide(color: k.line))),
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 36),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 48, runSpacing: 20, children: [
          for (final s in stats)
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(s.$1, style: KType.mono(k.text, 34, w: FontWeight.w600)),
              Text(context.t(s.$2), style: context.tt.bodySmall),
            ]),
        ]),
        const SizedBox(height: 36),
        Cols([
          for (final p in points)
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(p.$1, style: KType.mono(k.accent, 12)),
              const SizedBox(height: 10),
              Text(context.t(p.$2), style: KType.display(k.text, 30)),
              const SizedBox(height: 8),
              Text(context.t(p.$3), style: TextStyle(color: k.muted, height: 1.5)),
            ]),
        ], gap: 36),
      ]),
    );
  }
}

/// Sign in / create account. Supabase when configured, demo backend otherwise.
class AuthCard extends StatefulWidget {
  const AuthCard({super.key});
  @override
  State<AuthCard> createState() => _AuthCardState();
}

class _AuthCardState extends State<AuthCard> {
  bool _signUp = false, _busy = false, _obscure = true;
  String? _error, _info;
  String _role = 'analyst';
  final _form = GlobalKey<FormState>();
  final _email = TextEditingController(), _password = TextEditingController();
  final _name = TextEditingController(), _org = TextEditingController();

  Future<void> _submit() async {
    if (!_form.currentState!.validate()) return;
    final st = context.read<AppState>();
    setState(() { _busy = true; _error = null; _info = null; });
    try {
      if (_signUp) {
        final confirm = await st.signUp(_email.text.trim(), _password.text,
            name: _name.text.trim(), org: _org.text.trim().isEmpty ? null : _org.text.trim(), role: _role);
        if (confirm) setState(() { _info = context.tr('checkEmail'); _signUp = false; });
      } else {
        await st.signIn(_email.text.trim(), _password.text);
      }
    } catch (e) {
      setState(() => _error = '${context.tr('authError')}${_detail(e)}');
    }
    if (mounted) setState(() => _busy = false);
  }

  String _detail(Object e) {
    final s = e.toString();
    final m = RegExp(r'message: ([^,)]+)').firstMatch(s);
    return m != null ? '\n${m.group(1)}' : '';
  }

  Future<void> _demo() async {
    _email.text = 'demo@kavach.ai';
    _password.text = 'demo1234';
    setState(() => _signUp = false);
    await _submit();
  }

  Future<void> _forgot() async {
    if (!_email.text.contains('@')) {
      setState(() => _error = context.tr('invalidEmail'));
      return;
    }
    await context.read<AppState>().account.resetPassword(_email.text.trim());
    setState(() => _info = context.tr('resetSent'));
  }

  @override
  Widget build(BuildContext context) {
    final k = context.k;
    final st = context.watch<AppState>();
    final roles = {'analyst': 'roleAnalyst', 'credit_officer': 'roleCredit', 'investor': 'roleInvestor',
      'treasury': 'roleTreasury', 'student': 'roleStudent', 'other': 'roleOther'};
    return Container(
      padding: const EdgeInsets.all(26),
      decoration: BoxDecoration(
        color: k.surface.withValues(alpha: 0.92),
        border: Border.all(color: k.lineStrong),
        borderRadius: BorderRadius.circular(8),
        boxShadow: [BoxShadow(color: Colors.black.withValues(alpha: 0.35), blurRadius: 40, offset: const Offset(0, 20))],
      ),
      child: Form(
        key: _form,
        child: AutofillGroup(
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, mainAxisSize: MainAxisSize.min, children: [
            Text(_signUp ? context.t('signUp') : context.t('signIn'), style: KType.display(k.text, 34)),
            const SizedBox(height: 4),
            Text(context.t('tagline'), style: context.tt.bodySmall),
            const SizedBox(height: 22),
            if (_signUp) ...[
              TextFormField(controller: _name, autofillHints: const [AutofillHints.name],
                  decoration: InputDecoration(labelText: context.t('fullName')),
                  validator: (v) => (v ?? '').trim().length < 2 ? context.t('required') : null),
              const SizedBox(height: 12),
              TextFormField(controller: _org, autofillHints: const [AutofillHints.organizationName],
                  decoration: InputDecoration(labelText: context.t('organisation'))),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: _role, dropdownColor: k.raised,
                decoration: InputDecoration(labelText: context.t('role')),
                items: [for (final r in roles.entries) DropdownMenuItem(value: r.key, child: Text(context.t(r.value)))],
                onChanged: (v) => setState(() => _role = v!),
              ),
              const SizedBox(height: 12),
            ],
            TextFormField(
              controller: _email, keyboardType: TextInputType.emailAddress, autofillHints: const [AutofillHints.email],
              decoration: InputDecoration(labelText: context.t('email')),
              validator: (v) => RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch((v ?? '').trim()) ? null : context.t('invalidEmail'),
            ),
            const SizedBox(height: 12),
            TextFormField(
              controller: _password, obscureText: _obscure,
              autofillHints: [_signUp ? AutofillHints.newPassword : AutofillHints.password],
              onFieldSubmitted: (_) => _submit(),
              decoration: InputDecoration(
                labelText: context.t('password'),
                helperText: _signUp ? context.t('passwordHint') : null,
                suffixIcon: IconButton(icon: Icon(_obscure ? Icons.visibility_outlined : Icons.visibility_off_outlined, size: 18),
                    onPressed: () => setState(() => _obscure = !_obscure)),
              ),
              validator: (v) => (v ?? '').length < (_signUp ? 8 : 1) ? context.t('passwordHint') : null,
            ),
            if (!_signUp && st.account.isSupabase)
              Align(alignment: AlignmentDirectional.centerEnd,
                  child: TextButton(onPressed: _forgot, child: Text(context.t('forgotPassword'), style: const TextStyle(fontSize: 12.5)))),
            if (_error != null) ...[
              const SizedBox(height: 10),
              Text(_error!, style: TextStyle(color: k.critical, fontSize: 13)),
            ],
            if (_info != null) ...[
              const SizedBox(height: 10),
              Text(_info!, style: TextStyle(color: k.low, fontSize: 13)),
            ],
            const SizedBox(height: 18),
            FilledButton(
              onPressed: _busy ? null : _submit,
              child: _busy ? SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: k.bg))
                  : Text(_signUp ? context.t('signUp') : context.t('signIn')),
            ),
            if (!st.account.isSupabase) ...[
              const SizedBox(height: 10),
              OutlinedButton(onPressed: _busy ? null : _demo, child: Text(context.t('continueDemo'))),
            ],
            const SizedBox(height: 14),
            Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              Text(_signUp ? context.t('haveAccount') : context.t('noAccount'), style: context.tt.bodySmall),
              TextButton(
                onPressed: () => setState(() { _signUp = !_signUp; _error = null; _info = null; }),
                child: Text(_signUp ? context.t('signIn') : context.t('signUp')),
              ),
            ]),
          ]),
        ),
      ),
    );
  }
}
