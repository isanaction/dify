#!/bin/bash

# エラーハンドリングを設定
set -e  # エラーが発生したらスクリプトを停止
trap 'echo "エラーが発生しました。スクリプトを中断します。"; exit 1' ERR

# 現在のディレクトリを保存（スクリプトの実行ディレクトリ）
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# バックアップの設定
BACKUP_DIR="${SCRIPT_DIR}/backups"
MAX_BACKUPS=5  # 保持するバックアップの最大数
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_PREFIX="${BACKUP_DIR}/dify_backup_${TIMESTAMP}"

# バックアップディレクトリの作成
mkdir -p ${BACKUP_DIR}

echo "バックアップを取ります..."
cd docker

# 設定ファイルのバックアップ（ファイルが存在する場合のみ）
if [ -f docker-compose.yaml ]; then
  cp docker-compose.yaml "${BACKUP_PREFIX}_docker-compose.yaml"
  echo "docker-compose.yamlをバックアップしました。"
else
  echo "警告: docker-compose.yamlが見つかりません。バックアップをスキップします。"
fi

if [ -f .env ]; then
  cp .env "${BACKUP_PREFIX}_.env"
  echo ".envファイルをバックアップしました。"
else
  echo "警告: .envファイルが見つかりません。バックアップをスキップします。"
fi

# ボリュームのバックアップ（ディレクトリが存在する場合のみ）
if [ -d volumes ]; then
  tar -czf "${BACKUP_PREFIX}_volumes.tgz" volumes
  echo "volumesディレクトリをバックアップしました。"
else
  echo "警告: volumesディレクトリが見つかりません。バックアップをスキップします。"
fi

# データベースバックアップ（PostgreSQLの場合の例）
# 実行中のコンテナをチェックする方法を改善
POSTGRES_RUNNING=$(docker compose ps --services --filter "status=running" 2>/dev/null | grep -c "postgres" || true)
if [ "$POSTGRES_RUNNING" -gt 0 ]; then
  echo "データベースのバックアップを取得しています..."
  if docker compose exec -T postgres pg_dumpall -c -U postgres > "${BACKUP_PREFIX}_database.sql" 2>/dev/null; then
    echo "データベースをバックアップしました。"
  else
    echo "警告: データベースのバックアップに失敗しました。スキップして続行します。"
  fi
else
  echo "警告: PostgreSQLサービスが実行されていません。データベースバックアップをスキップします。"
fi

echo "古いバックアップを整理しています..."
# 古いバックアップを削除（最新の$MAX_BACKUPS個を残す）
if ls ${BACKUP_DIR}/dify_backup_* >/dev/null 2>&1; then
  ls -t ${BACKUP_DIR}/dify_backup_* | tail -n +$((MAX_BACKUPS + 1)) | xargs rm -f 2>/dev/null || true
fi

echo "バックアップが完了しました。"

cd "${SCRIPT_DIR}"

echo "gitリポジトリの状態を確認しています..."
# 未コミットの変更があるか確認
if ! git diff --quiet; then
  echo "警告: コミットされていない変更があります。続行しますか？ (y/n)"
  read answer
  if [ "$answer" != "y" ]; then
    echo "更新を中止します。"
    exit 1
  fi
fi

echo "上流リポジトリから最新の変更を取得します..."
git fetch upstream

echo "mainブランチに切り替えます..."
git checkout main || { echo "mainブランチへの切り替えに失敗しました"; exit 1; }

echo "上流の変更をマージします..."
# コミットメッセージを自動的に設定してマージを実行
if ! git merge upstream/main -m "Upstream changes merged on $(date '+%Y-%m-%d %H:%M:%S')"; then
  echo "マージコンフリクトが発生しました。"
  echo "コンフリクトを解決してから再度スクリプトを実行してください。"
  echo "マージを中止します: git merge --abort"
  git merge --abort
  exit 1
fi

echo "変更をオリジンにプッシュします..."
git push origin main || { echo "プッシュに失敗しました"; exit 1; }

echo "ローカルのmainブランチを最新のコミットに更新します..."
git pull origin main

echo "dockerコンテナを停止します..."
cd docker
docker compose down

echo "dockerコンテナを起動します..."
docker compose up -d

# コンテナが起動するまで待機
echo "サービスの起動を待機しています..."
sleep 10

# サービスの正常性チェック
echo "サービスの正常性をチェックしています..."
if ! docker compose ps | grep -q "Up"; then
  echo "警告: 一部のサービスが正常に起動していない可能性があります。"
  docker compose ps
  echo "ログを確認してください: docker compose logs"
  exit 1
else
  echo "すべてのサービスが正常に起動しています。"
fi

echo "更新が完了しました。"
echo "問題が発生した場合は、バックアップファイル（${BACKUP_PREFIX}*）から復元できます。"
