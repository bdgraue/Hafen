// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hafen contributors

#include "docker.h"

#include <QProcess>
#include <QQmlEngine>

void Docker::run(const QStringList &args, const QJSValue &callback)
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
        if (status == QProcess::CrashExit) {
            finish(-1, out, err.isEmpty() ? QStringLiteral("docker ist abgestürzt") : err);
            return;
        }
        finish(code, out, err);
    });
    // A process that never started emits no finished(), so this is its only answer.
    connect(process, &QProcess::errorOccurred, this, [process, finish](QProcess::ProcessError error) {
        if (error == QProcess::FailedToStart) {
            finish(-1, QString(), process->errorString());
        }
    });

    process->start(QStringLiteral("docker"), args);
}
