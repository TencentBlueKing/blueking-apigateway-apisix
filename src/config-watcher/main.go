/*
 * TencentBlueKing is pleased to support the open source community by making
 * 蓝鲸智云 - API 网关(BlueKing - APIGateway) available.
 * Copyright (C) 2025 Tencent. All rights reserved.
 * Licensed under the MIT License (the "License"); you may not use this file except
 * in compliance with the License. You may obtain a copy of the License at
 *
 *     http://opensource.org/licenses/MIT
 *
 * Unless required by applicable law or agreed to in writing, software distributed under
 * the License is distributed on an "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND,
 * either express or implied. See the License for the specific language governing permissions and
 * limitations under the License.
 *
 * We undertake not to change the open source license (MIT license) applicable
 * to the current version of the project delivered to anyone in the future.
 */

package main

import (
	"flag"
	"fmt"
	"io"
	"io/ioutil"
	"os"
	"path/filepath"
	"strings"
	"time"

	"github.com/fsnotify/fsnotify"
	"go.uber.org/zap"
	"k8s.io/client-go/util/workqueue"
)

var (
	sourcePath  string
	destPath    string
	files       string
	isConfigMap bool
	copyHidden  bool
	logger      *zap.Logger
	workQueue   workqueue.DelayingInterface
)

type CopyMessage struct {
	source      string
	destination string
	filename    string
}

func main() {
	flag.StringVar(&sourcePath, "sourcePath", "/data/config", "parent path for standalone config (apisix.yaml)")
	flag.StringVar(
		&destPath,
		"destPath",
		"/usr/local/apisix/config",
		"parent path for apisix configs (config.yaml or config_default.yaml)",
	)
	flag.StringVar(
		&files,
		"files",
		"",
		"filename for watch and copy, seperate with comma(,). Default watching and copying all files in sourcePath",
	)
	flag.BoolVar(&isConfigMap, "isConfigMap", false, "whether configSourcePath is mounted from a configmap")
	flag.BoolVar(&copyHidden, "copyHidden", false, "whether copy hidden files")
	flag.Parse()

	logger, _ = zap.NewDevelopment()
	logger = logger.Named("config-watcher")

	workQueue = workqueue.NewDelayingQueue()
	go copyDaemon()
	filesList := strings.Split(files, ",")
	if strings.Trim(files, " ") == "" {
		filesList = make([]string, 0)
	}
	watchAndCopy(sourcePath, destPath, filesList)
}

func watchAndCopy(source, dest string, files []string) {
	// startup copy
	for _, file := range files {
		workQueue.Add(CopyMessage{
			source:      source,
			destination: dest,
			filename:    file,
		})
	}

	// event trigger copy
	allFiles := len(files) == 0
	fileFilter := make(map[string]struct{})
	for _, file := range files {
		fileFilter[file] = struct{}{}
	}
	watcher, err := fsnotify.NewWatcher()
	if err != nil {
		logger.Sugar().Panicf("Create file watcher failed: %s", err.Error())
	}
	watcher.Add(source)
	for {
		select {
		case event := <-watcher.Events:
			if event.Op&fsnotify.Remove == fsnotify.Remove {
				logger.Sugar().Infof("remove event triggered, skipped. %v", event)
				break
			}
			logger.Sugar().Infof("event triggered: %v", event)
			filename := filepath.Base(event.Name)
			if !isConfigMap {
				if _, ok := fileFilter[filename]; !ok && !allFiles {
					break
				}
				workQueue.AddAfter(CopyMessage{
					source:      source,
					destination: dest,
					filename:    filename,
				}, time.Second)
			} else {
				if configMapUpdateTrigger(filename, event.Op) {
					if !allFiles {
						for _, file := range files {
							workQueue.Add(CopyMessage{
								source:      source,
								destination: dest,
								filename:    file,
							})
						}
					} else {
						workQueue.Add(CopyMessage{
							source:      source,
							destination: dest,
							filename:    "",
						})
					}
				}
			}
		}
	}
}

func configMapUpdateTrigger(filename string, op fsnotify.Op) bool {
	if filename == "..data" && (op&fsnotify.Create == fsnotify.Create) {
		return true
	}
	return false
}

func copyDaemon() {
	for {
		item, done := workQueue.Get()
		if done {
			return
		}
		copyMessage, ok := item.(CopyMessage)
		if !ok {
			logger.Sugar().Errorf("Get copy message from workqueue failed, item: %+v", item)
			workQueue.Done(item)
			continue
		}
		err := copyTo(copyMessage.source, copyMessage.destination, copyMessage.filename)
		if err != nil {
			workQueue.AddAfter(item, time.Second)
		}
		workQueue.Done(item)
	}
}

func copyTo(source string, dest string, filename string) error {
	l := logger.With(zap.Any("source", source), zap.Any("dest", dest), zap.Any("filename", filename))
	// deal with single file or single directory copy
	if filename != "" {
		if strings.HasPrefix(filename, ".") && !copyHidden {
			logger.Sugar().Infof("Hidden file is ignored, filename: %s", filename)
			return nil
		}
		sourceFilePath := filepath.Join(source, filename)
		info, err := os.Stat(sourceFilePath)
		if err != nil {
			if os.IsNotExist(err) {
				l.Sugar().Errorf("source file does not exist, %s", err.Error())
				return nil
			}
			l.Sugar().Errorf("Stat source file failed, %s", err.Error())
			return err
		}
		// single dir copy
		if info.IsDir() {
			return copyTo(sourceFilePath, dest, "")
		}
		_, err = os.Stat(dest)
		if os.IsNotExist(err) {
			err := os.MkdirAll(dest, info.Mode())
			if err != nil {
				l.Sugar().Errorf("Create dest dir failed, %s", err.Error())
				return err
			}
		}
		// single file copy
		destFilePath := filepath.Join(dest, filename)
		err = copySingle(sourceFilePath, destFilePath)
		if err != nil {
			l.Sugar().Errorf("Copy file failed, %s", err.Error())
			return err
		}
		return nil
	}

	// dir copy
	sourceInfo, err := os.Stat(source)
	if err != nil {
		if os.IsNotExist(err) {
			l.Sugar().Errorf("source file does not exist, %s", err.Error())
			return nil
		}
		l.Sugar().Errorf("Stat source dir failed, %s", err.Error())
		return err
	}
	if !sourceInfo.IsDir() {
		l.Sugar().Errorf("Source path is not directory")
		return fmt.Errorf("Source path is not directory")
	}
	_, err = os.Stat(dest)
	if os.IsNotExist(err) {
		err := os.MkdirAll(dest, sourceInfo.Mode())
		if err != nil {
			l.Sugar().Errorf("Create dest dir failed, %s", err.Error())
			return err
		}
	}
	sourceDir, err := ioutil.ReadDir(source)
	if err != nil {
		l.Sugar().Errorf("Read source directory failed, %s", err.Error())
		return err
	}
	copyFailed := false
	for _, path := range sourceDir {
		if strings.HasPrefix(path.Name(), ".") && !copyHidden {
			continue
		}
		if path.IsDir() {
			innerSourcePath := filepath.Join(source, path.Name())
			innerDestPath := filepath.Join(dest, path.Name())
			err := copyTo(innerSourcePath, innerDestPath, "")
			if err != nil {
				copyFailed = true
				l.Sugar().Errorf("Copy file from %s to %s failed, %s", innerSourcePath, innerDestPath, err.Error())
			}
		} else {
			innerSourceFile := filepath.Join(source, path.Name())
			innerDestFile := filepath.Join(dest, path.Name())
			err := copySingle(innerSourceFile, innerDestFile)
			if err != nil {
				copyFailed = true
				l.Sugar().Errorf("Copy file from %s to %s failed, %s", innerSourceFile, innerDestFile, err.Error())
			}
		}
	}
	if copyFailed {
		return fmt.Errorf("Copy file from %s to %s failed", source, dest)
	}
	return nil
}

func copySingle(sourceFilePath, destFilePath string) error {
	l := logger.With(zap.Any("sourceFilePath", sourceFilePath), zap.Any("destFilePath", destFilePath))
	sourceFile, err := os.Open(sourceFilePath)
	if err != nil {
		l.Sugar().Errorf("Open source file failed, %s", err.Error())
		return err
	}
	sourceFileInfo, err := os.Stat(sourceFilePath)
	if err != nil {
		l.Sugar().Errorf("Lstate source file failed, %s", err.Error())
		return err
	}
	mode := sourceFileInfo.Mode()
	defer sourceFile.Close()
	_, err = os.Stat(destFilePath)
	if err != nil {
		if !os.IsNotExist(err) {
			l.Sugar().Errorf("Stat destination file failed, %s", err.Error())
			return err
		}
	}
	bakFilePath := filepath.Join(
		filepath.Dir(destFilePath),
		fmt.Sprintf(".%s.bak.config-watcher", filepath.Base(destFilePath)),
	)
	os.Rename(destFilePath, bakFilePath)
	destFile, err := os.OpenFile(destFilePath, os.O_RDWR|os.O_CREATE|os.O_TRUNC, mode)
	if err != nil {
		l.Sugar().Errorf("Open/Create dest file failed, %s", err.Error())
		return err
	}
	length, err := io.Copy(destFile, sourceFile)
	if err != nil {
		l.Sugar().Errorf("Copy failed, recover file. err: %s", err.Error())
		destFile.Close()
		os.Rename(bakFilePath, destFilePath)
		return err
	}
	l.Sugar().Infof("Copy succ, length: %d", length)
	destFile.Close()
	os.Remove(bakFilePath)
	return nil
}
