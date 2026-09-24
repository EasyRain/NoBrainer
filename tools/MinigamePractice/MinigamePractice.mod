return {
	run = function()
		fassert(rawget(_G, "new_mod"), "`MinigamePractice` encountered an error loading the Darktide Mod Framework.")

		new_mod("MinigamePractice", {
			mod_script = "MinigamePractice/scripts/mods/MinigamePractice/MinigamePractice",
		})
	end,
	packages = {},
}
