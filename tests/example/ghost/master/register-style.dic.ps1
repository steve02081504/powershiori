# A dictionary in imperative style: call Register-ShioriEvent instead of returning a hashtable.

Register-ShioriEvent OnRegisterStyle {
	param($context)
	'from-register-style'
}

Register-ShioriEvent OnWithPriorityFallback {
	param($context)
	''
}

Register-ShioriEvent OnWithPriorityFallback {
	param($context)
	"fallback-ok: $($context.Reference[0])"
}
