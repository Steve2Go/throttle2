Section("Settings"){
                                    Button("Manage Servers", systemImage: "rectangle.connected.to.line.below"){
                                        activeSheet = .servers
                                    }.buttonStyle(.plain)
                                    Button("App Settings", systemImage: "gearshape"){
                                        activeSheet = .settings
                                    }.buttonStyle(.plain)
                                }