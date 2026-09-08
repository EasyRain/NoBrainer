return {
	run = function()
		fassert(rawget(_G, "new_mod"), "`NoBrainer` encountered an error loading the Darktide Mod Framework.")

		new_mod("NoBrainer", {
			mod_script       = "NoBrainer/scripts/mods/NoBrainer/NoBrainer",
			mod_data         = "NoBrainer/scripts/mods/NoBrainer/NoBrainer_data",
			mod_localization = "NoBrainer/scripts/mods/NoBrainer/NoBrainer_localization",
		})
	end,
	packages = {},
}
