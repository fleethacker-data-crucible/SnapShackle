# GHAS alert triage (sprint 2026-11)

Open code-scanning alerts in this repo at the start of the sprint. Nothing here was dismissed on GitHub. Every alert is fixed, so no GitHub dismissal reason applies.

| Alert | Rule | Path | Disposition | Reason | GitHub dismissal |
| --- | --- | --- | --- | --- | --- |
| code-scanning #1 | py/bad-tag-filter | tests/ai_ui_test.py | fixed | The copied script-stripping regular expression missed end tags a browser still closes, such as `</script >`. `tests/studio_page.py` removes those elements with `html.parser`, and the test reattaches the same asset files. | n/a |
| code-scanning #2 | py/bad-tag-filter | tests/browser_smoke.py | fixed | The copied script-stripping regular expression missed end tags a browser still closes, such as `</script >`. `tests/studio_page.py` removes those elements with `html.parser`, and the test reattaches the same asset files. | n/a |
| code-scanning #3 | py/bad-tag-filter | tests/layers_a11y_test.py | fixed | The copied script-stripping regular expression missed end tags a browser still closes, such as `</script >`. `tests/studio_page.py` removes those elements with `html.parser`, and the test reattaches the same asset files. | n/a |
| code-scanning #4 | py/bad-tag-filter | tests/layers_numeric_test.py | fixed | The copied script-stripping regular expression missed end tags a browser still closes, such as `</script >`. `tests/studio_page.py` removes those elements with `html.parser`, and the test reattaches the same asset files. | n/a |
| code-scanning #5 | py/bad-tag-filter | tests/redact_flow_test.py | fixed | The copied script-stripping regular expression missed end tags a browser still closes, such as `</script >`. `tests/studio_page.py` removes those elements with `html.parser`, and the test reattaches the same asset files. | n/a |
| code-scanning #6 | py/bad-tag-filter | tests/share_ui_test.py | fixed | The copied script-stripping regular expression missed end tags a browser still closes, such as `</script >`. `tests/studio_page.py` removes those elements with `html.parser`, and the test reattaches the same asset files. | n/a |
| code-scanning #7 | py/bad-tag-filter | tests/voice_browser_test.py | fixed | The copied script-stripping regular expression missed end tags a browser still closes, such as `</script >`. `tests/studio_page.py` removes those elements with `html.parser`, and the test reattaches the same asset files. | n/a |
| code-scanning #8 | py/bad-tag-filter | tests/webcam_browser_test.py | fixed | The copied script-stripping regular expression missed end tags a browser still closes, such as `</script >`. `tests/studio_page.py` removes those elements with `html.parser`, and the test reattaches the same asset files. | n/a |
