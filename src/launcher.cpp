// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hafen contributors

#include "launcher.h"

#include <QCoreApplication>
#include <QDir>
#include <QFile>
#include <QFileInfo>
#include <QJsonDocument>
#include <QJsonObject>
#include <QNetworkAccessManager>
#include <QNetworkReply>
#include <QNetworkRequest>
#include <QProcess>
#include <QStandardPaths>
#include <QVariantMap>

namespace
{
const auto LatestReleaseApi = QStringLiteral("https://api.github.com/repos/bdgraue/Hafen/releases/latest");
const auto ReleasesPage = QStringLiteral("https://github.com/bdgraue/Hafen/releases");

}

Launcher::Launcher(QObject *parent)
    : QObject(parent)
{
}

QString Launcher::detached(const QStringList &argv)
{
    if (argv.isEmpty()) {
        return tr("No program given.");
    }
    const QString program = QStandardPaths::findExecutable(argv.first());
    if (program.isEmpty()) {
        return tr("%1 was not found.").arg(argv.first());
    }
    if (!QProcess::startDetached(program, argv.mid(1))) {
        return tr("%1 could not be started.").arg(argv.first());
    }
    return QString();
}

QVariantList Launcher::terminalEntries() const
{
    QVariantList entries;
    // Earlier locations win (the user's own entries first), so the order of the list matters.
    for (const QString &dir : QStandardPaths::standardLocations(QStandardPaths::ApplicationsLocation)) {
        const auto files = QDir(dir).entryInfoList({QStringLiteral("*.desktop")}, QDir::Files | QDir::Readable, QDir::Name);
        for (const QFileInfo &info : files) {
            QFile file(info.filePath());
            if (!file.open(QIODevice::ReadOnly)) {
                continue;
            }
            const QString content = QString::fromUtf8(file.readAll());
            if (!content.contains(QStringLiteral("TerminalEmulator"))) {
                continue;
            }
            entries.append(QVariantMap{{QStringLiteral("id"), info.fileName()}, {QStringLiteral("content"), content}});
        }
    }
    return entries;
}

bool Launcher::hasProgram(const QString &name) const
{
    return !QStandardPaths::findExecutable(name).isEmpty();
}

void Launcher::checkForUpdate()
{
    if (!m_network) {
        m_network = new QNetworkAccessManager(this);
    }
    QNetworkRequest request{QUrl(LatestReleaseApi)};
    // GitHub's API rejects requests without a User-Agent.
    request.setHeader(QNetworkRequest::UserAgentHeader, QStringLiteral("Hafen/%1").arg(version()));
    request.setRawHeader("Accept", "application/vnd.github+json");
    request.setTransferTimeout(15000);

    QNetworkReply *reply = m_network->get(request);
    connect(reply, &QNetworkReply::finished, this, [this, reply] {
        reply->deleteLater();
        const int status = reply->attribute(QNetworkRequest::HttpStatusCodeAttribute).toInt();
        // No release published yet: nothing to update to.
        if (status == 404) {
            Q_EMIT updateChecked(QString(), ReleasesPage);
            return;
        }
        if (reply->error() != QNetworkReply::NoError) {
            Q_EMIT updateFailed(reply->errorString());
            return;
        }
        const auto release = QJsonDocument::fromJson(reply->readAll()).object();
        const QString tag = release.value(QStringLiteral("tag_name")).toString();
        const QString url = release.value(QStringLiteral("html_url")).toString();
        if (tag.isEmpty() || url.isEmpty()) {
            Q_EMIT updateFailed(tr("GitHub did not report a version."));
            return;
        }
        Q_EMIT updateChecked(tag, url);
    });
}

QString Launcher::version() const
{
    return QCoreApplication::applicationVersion();
}

QString Launcher::releasesUrl() const
{
    return ReleasesPage;
}

QString Launcher::autostartFile() const
{
    return QStandardPaths::writableLocation(QStandardPaths::GenericConfigLocation) + QStringLiteral("/autostart/")
        + QCoreApplication::applicationName() + QStringLiteral(".desktop");
}

bool Launcher::autostart() const
{
    return QFileInfo::exists(autostartFile());
}

void Launcher::setAutostart(bool enabled)
{
    if (enabled == autostart()) {
        return;
    }
    const QString path = autostartFile();
    if (!enabled) {
        if (!QFile::remove(path)) {
            Q_EMIT autostartFailed(tr("%1 could not be removed.").arg(path));
        }
        Q_EMIT autostartChanged();
        return;
    }
    if (!QDir().mkpath(QFileInfo(path).absolutePath())) {
        Q_EMIT autostartFailed(tr("The folder for %1 could not be created.").arg(path));
        Q_EMIT autostartChanged();
        return;
    }
    QFile file(path);
    if (!file.open(QIODevice::WriteOnly | QIODevice::Truncate)) {
        Q_EMIT autostartFailed(tr("%1 could not be written: %2").arg(path, file.errorString()));
        Q_EMIT autostartChanged();
        return;
    }
    // The running binary's path, so a build from source starts the same Hafen that ticked the box.
    file.write(QStringLiteral("[Desktop Entry]\nType=Application\nName=Hafen\nExec=\"%1\" --hidden\nIcon=%2\nX-GNOME-Autostart-enabled=true\n")
                   .arg(QCoreApplication::applicationFilePath(), QStringLiteral("io.github.bdgraue.Hafen"))
                   .toUtf8());
    Q_EMIT autostartChanged();
}
