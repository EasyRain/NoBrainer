return {
	run = function()
		fassert(rawget(_G, "new_mod"), "`MinigameProbe` encountered an error loading the Darktide Mod Framework.")

		new_mod("MinigameProbe", {
			mod_script = "MinigameProbe/scripts/mods/MinigameProbe/MinigameProbe",
		})
	end,
	packages = {},
}
