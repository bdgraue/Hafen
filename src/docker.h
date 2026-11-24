// SPDX-License-Identifier: GPL-3.0-or-later
// SPDX-FileCopyrightText: 2026 Hafen contributors

#pragma once

#include <QJSValue>
#include <QObject>
#include <QStringList>
#include <QtQml/qqmlregistration.h>

class Docker : public QObject
{
    Q_OBJECT
    QML_ELEMENT
    QML_SINGLETON

public:
    using QObject::QObject;

    // Runs the docker CLI without blocking and calls back with (exitCode, stdout, stderr).
    // exitCode is -1 when docker could not start or crashed; stderr then holds the reason.
    Q_INVOKABLE void run(const QStringList &args, const QJSValue &callback);
};
