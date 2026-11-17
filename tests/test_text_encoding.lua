local H = RGTest

H.Test("user text keeps complete UTF-8 and rejects invalid or hidden formatting bytes", function()
    local U = H.Addon().Util
    H.Equal(U.Text("  Роса-艾露恩  ", 40), "Роса-艾露恩")
    H.Equal(U.Text("Watch 🛡", 40), "Watch 🛡")
    H.Nil(U.Text(string.char(0xD0), 40))
    H.Nil(U.Text(string.char(0xC0, 0xAF), 40))
    H.Nil(U.Text(string.char(0xED, 0xA0, 0x80), 40))
    H.Nil(U.Text(string.char(0xF4, 0x90, 0x80, 0x80), 40))
    H.Nil(U.Text("name" .. string.char(0xE2, 0x80, 0xAE), 40))
end)
