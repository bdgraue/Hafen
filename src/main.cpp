// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hafen contributors

#include <KDBusService>
#include <QApplication>
#include <QCommandLineParser>
#include <QIcon>
#include <QQmlApplicationEngine>
#include <QQuickStyle>
#include <QWindow>

int main(int argc, char *argv[])
{
    QApplication app(argc, argv);
    QApplication::setApplicationName(QStringLiteral("hafen"));
    QApplication::setApplicationDisplayName(QStringLiteral("Hafen"));
    QApplication::setApplicationVersion(QStringLiteral(HAFEN_VERSION));
    // Registers on D-Bus as io.github.bdgraue.hafen.
    QApplication::setOrganizationDomain(QStringLiteral("bdgraue.github.io"));
    // Settings land in ~/.config/hafen/hafen.conf instead of a folder named after the domain.
    QApplication::setOrganizationName(QStringLiteral("hafen"));
    QApplication::setDesktopFileName(QStringLiteral("io.github.bdgraue.Hafen"));
    QApplication::setWindowIcon(QIcon(QStringLiteral(":/qt/qml/Hafen/data/hafen.svg")));
    // Closing the window only hides it; the tray icon keeps the app running.
    QApplication::setQuitOnLastWindowClosed(false);

    QCommandLineParser parser;
    parser.setApplicationDescription(QStringLiteral("Docker-Container nach Compose-Projekt im Tray."));
    parser.addHelpOption();
    parser.addVersionOption();
    const QCommandLineOption hidden(QStringLiteral("hidden"), QStringLiteral("Nur das Tray-Icon zeigen, das Fenster bleibt versteckt."));
    parser.addOption(hidden);
    parser.process(app);

    if (qEnvironmentVariableIsEmpty("QT_QUICK_CONTROLS_STYLE")) {
        QQuickStyle::setStyle(QStringLiteral("org.kde.desktop"));
    }

    // A second launch exits here and brings the running window to the front instead.
    KDBusService service(KDBusService::Unique);

    QQmlApplicationEngine engine;
    engine.setInitialProperties({{QStringLiteral("startHidden"), parser.isSet(hidden)}});
    engine.loadFromModule("Hafen", "Main");
    if (engine.rootObjects().isEmpty()) {
        return 1;
    }

    auto *window = qobject_cast<QWindow *>(engine.rootObjects().constFirst());
    if (!window) {
        qFatal("Main.qml ist kein Fenster.");
    }
    QObject::connect(&service, &KDBusService::activateRequested, window, [window] {
        window->show();
        window->raise();
        window->requestActivate();
    });

    return app.exec();
}
