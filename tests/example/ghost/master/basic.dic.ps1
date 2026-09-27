# Example PowerShell shiori dictionary.
#
# Either `return @{ Event = { ... } }` (as here) or call Register-ShioriEvent from a plain script.
# A handler is invoked as `& $handler $context`; declare `param($context)` to receive it.
# Return a SakuraScript string, or an empty string to fall through to an earlier handler / the
# built-in default response.

@{
	OnBoot = {
		param($context)
		'\0\s[0]\1\s[10]\e'
	}

	OnMouseDoubleClick = {
		param($context)
		"\0你好，我是纯 PowerShell 写成的 shiori 哦。\e"
	}

	OnTestEcho = {
		param($context)
		"OnTestEcho reference0=[$($context.Reference[0])]"
	}

	OnStatic = 'static-string-response'
}
