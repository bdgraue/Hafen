// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hafen contributors

#include "docker.h"

#include <QFile>
#include <QProcess>
#include <QQmlEngine>
#include <QRegularExpression>
#include <QThread>
#include <QTimer>

namespace
{
// A stream that broke (daemon restart, context switch) is retried after this delay; polling covers the gap.
constexpr int ReconnectMs = 5000;
}

Docker::Docker(QObject *parent)
    : QObject(parent)
    , m_reconnect(new QTimer(this))
{
    m_reconnect->setSingleShot(true);
    m_reconnect->setInterval(ReconnectMs);
    connect(m_reconnect, &QTimer::timeout, this, &Docker::launchWatcher);
}

QStringList Docker::contextArgs() const
{
    return m_context.isEmpty() ? QStringList() : QStringList{QStringLiteral("--context"), m_context};
}

void Docker::run(const QStringList &args, const QJSValue &callback, int timeoutMs)
{
    if (!callback.isCallable()) {
        qmlEngine(this)->throwError(QStringLiteral("Docker.run needs a callback function."));
        return;
    }

    auto *process = new QProcess(this);
    auto finish = [process, callback](int code, const QString &out, const QString &err) {
        QJSValue(callback).call({QJSValue(code), QJSValue(out), QJSValue(err)});
        process->deleteLater();
    };

    connect(process, &QProcess::finished, this, [process, finish](int code, QProcess::ExitStatus status) {
        const QString out = QString::fromUtf8(process->readAllStandardOutput());
        const QString err = QString::fromUtf8(process->readAllStandardError());
        if (process->property("timedOut").toBool()) {
            finish(-1, out, tr("docker did not answer and was stopped."));
            return;
        }
        if (status == QProcess::CrashExit) {
            finish(-1, out, err.isEmpty() ? tr("docker crashed.") : err);
            return;
        }
        finish(code, out, err);
    });
    // A process that never started emits no finished(), so this is its only answer.
    connect(process, &QProcess::errorOccurred, this, [process, finish](QProcess::ProcessError error) {
        if (error == QProcess::FailedToStart) {
            finish(-2, QString(), process->errorString());
        }
    });

    // A hanging daemon would otherwise keep the caller's "loading" state forever, and with it every later refresh.
    if (timeoutMs > 0) {
        QTimer::singleShot(timeoutMs, process, [process] {
            process->setProperty("timedOut", true);
            process->kill();
        });
    }
    process->start(QStringLiteral("docker"), contextArgs() + args);
}

void Docker::startWatching()
{
    m_wantWatching = true;
    if (!m_events) {
        launchWatcher();
    }
}

void Docker::stopWatching()
{
    m_wantWatching = false;
    m_reconnect->stop();
    if (m_events) {
        m_events->disconnect(this);
        m_events->kill();
        m_events->deleteLater();
        m_events = nullptr;
    }
    setWatching(false);
}

void Docker::launchWatcher()
{
    if (!m_wantWatching || m_events) {
        return;
    }
    m_buffer.clear();
    auto *process = new QProcess(this);
    m_events = process;
    process->setProcessChannelMode(QProcess::SeparateChannels);

    connect(process, &QProcess::started, this, [this] {
        setWatching(true);
    });
    connect(process, &QProcess::readyReadStandardOutput, this, [this, process] {
        m_buffer += process->readAllStandardOutput();
        qsizetype newline;
        while ((newline = m_buffer.indexOf('\n')) >= 0) {
            const QByteArray line = m_buffer.left(newline).trimmed();
            m_buffer.remove(0, newline + 1);
            if (!line.isEmpty()) {
                Q_EMIT containerEvent(QString::fromUtf8(line));
            }
        }
    });
    auto ended = [this, process] {
        process->deleteLater();
        if (m_events == process) {
            m_events = nullptr;
        }
        setWatching(false);
        if (m_wantWatching) {
            m_reconnect->start();
        }
    };
    connect(process, &QProcess::finished, this, ended);
    connect(process, &QProcess::errorOccurred, this, [ended](QProcess::ProcessError error) {
        if (error == QProcess::FailedToStart) {
            ended();
        }
    });

    process->start(QStringLiteral("docker"),
                   contextArgs()
                       + QStringList{QStringLiteral("events"),
                                     QStringLiteral("--filter"),
                                     QStringLiteral("type=container"),
                                     QStringLiteral("--format"),
                                     QStringLiteral("{{json .}}")});
}

void Docker::setWatching(bool watching)
{
    if (m_watching == watching) {
        return;
    }
    m_watching = watching;
    Q_EMIT watchingChanged();
}

int Docker::cpuCount() const
{
    return QThread::idealThreadCount();
}

double Docker::memoryTotal() const
{
    QFile meminfo(QStringLiteral("/proc/meminfo"));
    if (!meminfo.open(QIODevice::ReadOnly)) {
        qFatal("/proc/meminfo is not readable.");
    }
    static const QRegularExpression line(QStringLiteral(R"(^MemTotal:\s+(\d+)\s+kB$)"), QRegularExpression::MultilineOption);
    const auto match = line.match(QString::fromLatin1(meminfo.readAll()));
    if (!match.hasMatch()) {
        qFatal("MemTotal is missing from /proc/meminfo.");
    }
    return match.captured(1).toDouble() * 1024;
}

bool Docker::watching() const
{
    return m_watching;
}

QString Docker::context() const
{
    return m_context;
}

void Docker::setContext(const QString &context)
{
    if (m_context == context) {
        return;
    }
    m_context = context;
    Q_EMIT contextChanged();
    // The running stream still follows the old daemon.
    if (m_wantWatching) {
        stopWatching();
        startWatching();
    }
}
