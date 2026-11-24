// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hafen contributors

#include "docker.h"

#include <QFile>
#include <QProcess>
#include <QQmlEngine>
#include <QRegularExpression>
#include <QThread>
#include <QTimer>

void Docker::run(const QStringList &args, const QJSValue &callback, int timeoutMs)
{
    if (!callback.isCallable()) {
        qmlEngine(this)->throwError(QStringLiteral("Docker.run braucht eine Callback-Funktion."));
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
            finish(-1, out, QStringLiteral("docker hat nicht geantwortet und wurde abgebrochen."));
            return;
        }
        if (status == QProcess::CrashExit) {
            finish(-1, out, err.isEmpty() ? QStringLiteral("docker ist abgestürzt") : err);
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
    process->start(QStringLiteral("docker"), args);
}

int Docker::cpuCount() const
{
    return QThread::idealThreadCount();
}

double Docker::memoryTotal() const
{
    QFile meminfo(QStringLiteral("/proc/meminfo"));
    if (!meminfo.open(QIODevice::ReadOnly)) {
        qFatal("/proc/meminfo ist nicht lesbar.");
    }
    static const QRegularExpression line(QStringLiteral(R"(^MemTotal:\s+(\d+)\s+kB$)"), QRegularExpression::MultilineOption);
    const auto match = line.match(QString::fromLatin1(meminfo.readAll()));
    if (!match.hasMatch()) {
        qFatal("MemTotal fehlt in /proc/meminfo.");
    }
    return match.captured(1).toDouble() * 1024;
}
