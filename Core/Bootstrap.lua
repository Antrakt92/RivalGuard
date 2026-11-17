local addonName, RG = ...

RG.name = addonName or "RivalGuard"
RG.version = "0.1.0-dev"
RG.schemaVersion = 1
RG.modules = {}

function RG.Register(name, module)
    assert(type(name) == "string" and RG[name] == nil, "duplicate module")
    RG[name] = module
    RG.modules[#RG.modules + 1] = name
    return module
end
