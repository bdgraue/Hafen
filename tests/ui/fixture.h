// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hafen contributors

#pragma once

#include <QObject>
#include <QStringList>
#include <QTemporaryDir>
#include <QVariantList>
#include <QVariantMap>

class QQmlEngine;

// What the UI tests stand on: a temporary directory with the fake docker's containers, PATH pointing at the fake
// docker, xdg-open and terminal, and settings kept away from the real ~/.config. Exposed to QML as `fixture`.
class Fixture : public QObject
{
    Q_OBJECT

public:
    Fixture();

    // Back to the scenario file, empty logs and default settings (no update check, the fake terminal).
    Q_INVOKABLE void reset();

    // Every docker call so far, each as its arguments joined by spaces.
    Q_INVOKABLE QStringList calls() const;
    // What Hafen started besides docker: [program, arg, …] per launch.
    Q_INVOKABLE QVariantList launched() const;

    // Change a container behind Hafen's back, as another terminal would, and report it through `docker events`.
    Q_INVOKABLE void patchContainer(const QString &id, const QVariantMap &changes);
    // Make docker commands starting with these words fail with this stderr text.
    Q_INVOKABLE void failCommand(const QString &words, const QString &stderrText);
    Q_INVOKABLE void setDaemonDown(bool down);
    // Rows of `docker context ls`: [{ Name, Current, DockerEndpoint, Error }].
    Q_INVOKABLE void setContexts(const QVariantList &contexts);
    Q_INVOKABLE void setSetting(const QString &key, const QVariant &value);
    Q_INVOKABLE QString path(const QString &name) const;
    // The content of a file below the temporary directory; an empty string when it does not exist.
    Q_INVOKABLE QString read(const QString &name) const;
    Q_INVOKABLE bool exists(const QString &name) const;
    // A file that outlives the test run, for screenshots: <build>/tests/ui/artifacts/<name>.
    Q_INVOKABLE QString artifact(const QString &name) const;

public Q_SLOTS:
    // Called by Qt Quick Test for every engine it creates.
    void qmlEngineAvailable(QQmlEngine *engine);

private:
    QStringList lines(const QString &name) const;
    void write(const QString &name, const QByteArray &content) const;

    QTemporaryDir m_dir;
};
