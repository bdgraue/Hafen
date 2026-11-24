// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hafen contributors

#pragma once

#include <QJSValue>
#include <QObject>
#include <QPointer>
#include <QStringList>
#include <QtQml/qqmlregistration.h>

class QProcess;
class QTimer;

class Docker : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON
    Q_PROPERTY(int cpuCount READ cpuCount CONSTANT)
    Q_PROPERTY(double memoryTotal READ memoryTotal CONSTANT)
    // Docker context for every call Hafen makes; empty uses the CLI's current context.
    Q_PROPERTY(QString context READ context WRITE setContext NOTIFY contextChanged)
    // True while `docker events` is connected and reporting changes.
    Q_PROPERTY(bool watching READ watching NOTIFY watchingChanged)

public:
    explicit Docker(QObject *parent = nullptr);
    ~Docker() override;

    // Runs the docker CLI without blocking and calls back with (exitCode, stdout, stderr).
    // exitCode is -2 when docker could not be started at all and -1 when it crashed or was killed after timeoutMs;
    // stderr then holds the reason. timeoutMs 0 waits as long as docker takes, e.g. for `compose up` pulling images.
    Q_INVOKABLE void run(const QStringList &args, const QJSValue &callback, int timeoutMs);

    // The arguments that select the context, for commands Hafen hands to a terminal.
    Q_INVOKABLE QStringList contextArgs() const;

    // Follows `docker events` for containers and emits containerEvent per line; reconnects when the stream ends.
    Q_INVOKABLE void startWatching();
    Q_INVOKABLE void stopWatching();

    int cpuCount() const;
    // Bytes of physical memory, from /proc/meminfo.
    double memoryTotal() const;
    QString context() const;
    void setContext(const QString &context);
    bool watching() const;

Q_SIGNALS:
    void contextChanged();
    void watchingChanged();
    void containerEvent(const QString &json);

private:
    void launchWatcher();
    void setWatching(bool watching);

    QString m_context;
    bool m_wantWatching = false;
    bool m_watching = false;
    QPointer<QProcess> m_events;
    QTimer *m_reconnect;
    QByteArray m_buffer;
};
