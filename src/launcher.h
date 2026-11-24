// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hafen contributors

#pragma once

#include <QObject>
#include <QStringList>
#include <QVariantList>
#include <QtQml/qqmlregistration.h>

class QNetworkAccessManager;

class Launcher : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    Q_PROPERTY(QString version READ version CONSTANT)
    Q_PROPERTY(QString releasesUrl READ releasesUrl CONSTANT)
    Q_PROPERTY(bool autostart READ autostart WRITE setAutostart NOTIFY autostartChanged)

public:
    explicit Launcher(QObject *parent = nullptr);

    // Starts a program that outlives Hafen, such as a terminal or the browser. Returns an error message, empty on success.
    Q_INVOKABLE QString detached(const QStringList &argv);

    // Desktop entries that mention TerminalEmulator, in XDG order: [{ id, content }]. model.mjs decides which are terminals.
    Q_INVOKABLE QVariantList terminalEntries() const;

    Q_INVOKABLE bool hasProgram(const QString &name) const;

    // Asks GitHub for the latest release; emits updateChecked(tag, url) or updateFailed(message).
    Q_INVOKABLE void checkForUpdate();

    QString version() const;
    QString releasesUrl() const;
    bool autostart() const;
    void setAutostart(bool enabled);

Q_SIGNALS:
    void autostartChanged();
    void autostartFailed(const QString &message);
    void updateChecked(const QString &tag, const QString &url);
    void updateFailed(const QString &message);

private:
    QString autostartFile() const;
    QNetworkAccessManager *m_network = nullptr;
};
